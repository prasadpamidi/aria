import Aria
import Foundation
import WorkflowKit

#if canImport(FoundationModels)
    import AriaApple
    import FoundationModels

    // MARK: - AgentRuntime

    /// Process-wide host for the agent stack — the agent analog of
    /// `WorkflowRuntime`, but reusable across apps. Bridges a compiled
    /// `Aria.Agent`'s `AgentEvent` stream into the app-level
    /// `AgentRunEvent` stream, handling approval parking, checkpoint
    /// events, and run-record lifecycle.
    ///
    /// App-agnostic: the host injects provider routing + extra tool
    /// sources at `boot`. `@available(iOS 26)` + `FoundationModels`
    /// because the agent tool surface routes through FoundationModels;
    /// the models + stores in AgentKit stay usable without it.
    @available(iOS 26.0, macOS 26.0, *)
    @MainActor
    public final class AgentRuntime {
        // MARK: Lifecycle

        private init(
            store: AgentStore,
            runStore: AgentRunStore,
            chatHistory: any ChatHistory,
            compiler: AgentCompiler
        ) {
            self.store = store
            self.runStore = runStore
            self.chatHistory = chatHistory
            self.compiler = compiler
        }

        // MARK: Public

        public private(set) static var shared: AgentRuntime?

        public let store: AgentStore
        public let runStore: AgentRunStore

        /// Install the runtime. Idempotent. Seeding default agents is
        /// the host's responsibility (call before `boot`).
        ///
        /// - Parameters:
        ///   - chatHistory / checkpointer: from the host's Aria storage
        ///     (e.g. AriaApple's `GRDBStorage`).
        ///   - broker: the host's `CapabilityBroker` (agents call
        ///     first-party, so they bypass grants).
        ///   - extraTools: host MCP / workflow / plugin / skill-load tools.
        ///   - makeProvider: host LLM routing (or
        ///     `AgentProviders.foundationModelsOnly`).
        public static func boot(
            store: AgentStore,
            runStore: AgentRunStore,
            chatHistory: any ChatHistory,
            checkpointer: any Checkpointer,
            broker: CapabilityBroker,
            skillProvider: SkillProvider?,
            extraTools: @escaping AgentExtraToolsProvider,
            makeProvider: @escaping AgentProviderFactory
        ) {
            guard self.shared == nil else {
                // Second `boot` calls are a no-op rather than a
                // crash — but they're also almost always a bug
                // (host trying to re-wire stores at runtime,
                // tests forgetting to reset, etc). Log so the
                // silent-ignore doesn't hide a wiring mistake.
                print("[AGENT] AgentRuntime.boot called after first boot — ignored. First-boot wiring still in effect.")
                return
            }
            let compiler = AgentCompiler(
                broker: broker,
                skillProvider: skillProvider,
                checkpointer: checkpointer,
                runStore: runStore,
                extraTools: extraTools,
                makeProvider: makeProvider
            )
            self.shared = AgentRuntime(
                store: store,
                runStore: runStore,
                chatHistory: chatHistory,
                compiler: compiler
            )
            // Sweep runs the previous process left mid-flight. A run in
            // `.running` after process restart is by definition orphaned
            // — the agent loop only lives in-memory. Mark it `.failed`
            // so the Active Runs list, Live Activity, and any UI showing
            // run state agree about reality.
            Self.recoverOrphanedRuns(runStore: runStore)
        }

        /// Mark any run still in `.running` as `.failed` — invoked at
        /// boot to clear ghost runs from a previous process. Safe to
        /// call multiple times; the predicate filters to runs that need
        /// fixing.
        public static func recoverOrphanedRuns(runStore: AgentRunStore) {
            guard let runs = try? runStore.list() else {
                return
            }
            for run in runs where run.status == .running {
                print("[AGENT] boot.sweep orphaned runID=\(run.id) — marking failed")
                _ = try? runStore.update(id: run.id) { row in
                    row.status = .failed
                    if (row.outputSummary ?? "").isEmpty {
                        row.outputSummary = "Interrupted — the app restarted before this run finished."
                    }
                }
            }
        }

        /// Launch a fresh run of `agentID`.
        public func runStreaming(
            agentID: UUID,
            input: String,
            attended: Bool,
            threadId: String? = nil
        ) -> AsyncThrowingStream<AgentRunEvent, any Error> {
            print(
                "[AGENT] runStreaming agentID=\(agentID) input=\"\(input)\" attended=\(attended) threadId=\(threadId ?? "(new)")"
            )
            return AsyncThrowingStream { continuation in
                let task = Task { @MainActor in
                    do {
                        guard let definition = try self.store.load(id: agentID) else {
                            throw AgentRuntimeError.agentNotFound(agentID)
                        }
                        print(
                            "[AGENT] runStreaming loaded definition name=\(definition.name) policy=\(definition.approvalPolicy)"
                        )
                        let record = try self.runStore.create(
                            agentID: agentID,
                            inputSummary: input,
                            threadId: threadId
                        )
                        print("[AGENT] runStreaming created runID=\(record.id) threadId=\(record.threadId)")
                        continuation.yield(.runStarted(runID: record.id))
                        let sink = AgentApprovalSink()
                        let agent = self.compiler.compile(
                            definition: definition,
                            runID: record.id,
                            threadId: record.threadId,
                            history: self.chatHistory,
                            recorder: SessionRecorder(),
                            attended: attended,
                            approvalSink: sink,
                            onCheckpoint: { checkpointID, step in
                                continuation.yield(.checkpointSaved(checkpointID: checkpointID, step: step))
                            }
                        )
                        try await self.drive(
                            agent: agent,
                            input: .message(.user(input)),
                            runID: record.id,
                            sink: sink,
                            isPostApprove: false,
                            continuation: continuation
                        )
                    } catch {
                        continuation.yield(.failed(Self.describe(error)))
                        continuation.finish()
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        /// Resume a paused / awaiting-approval run. History replay (via
        /// `HistoryMiddleware` on the same `threadId`) rehydrates the
        /// conversation; a continuation nudge re-enters the loop.
        ///
        /// Contract: when resolving an approval, the host executes the
        /// proposed side effect first, then calls this with
        /// `approval: .approve`.
        public func resumeStreaming(
            runID: UUID,
            approval: ApprovalResolution? = nil
        ) -> AsyncThrowingStream<AgentRunEvent, any Error> {
            print("[AGENT] resumeStreaming runID=\(runID) approval=\(approval.map(String.init(describing:)) ?? "nil")")
            return AsyncThrowingStream { continuation in
                let task = Task { @MainActor in
                    do {
                        guard let record = try self.runStore.load(id: runID) else {
                            throw AgentRuntimeError.runNotFound(runID)
                        }
                        guard let definition = try self.store.load(id: record.agentID) else {
                            throw AgentRuntimeError.agentNotFound(record.agentID)
                        }
                        let nudge = Self.resumeNudge(record: record, approval: approval)
                        print(
                            "[AGENT] resumeStreaming nudge=\"\(nudge)\" status=\(record.status) pendingKind=\(record.pendingProposal?.kind ?? "nil")"
                        )
                        continuation.yield(.runStarted(runID: record.id))
                        _ = try? self.runStore.update(id: runID) { row in
                            row.status = .running
                            row.pendingProposal = nil
                        }
                        let sink = AgentApprovalSink()
                        let agent = self.compiler.compile(
                            definition: definition,
                            runID: record.id,
                            threadId: record.threadId,
                            history: self.chatHistory,
                            recorder: SessionRecorder(),
                            attended: true,
                            approvalSink: sink,
                            onCheckpoint: { checkpointID, step in
                                continuation.yield(.checkpointSaved(checkpointID: checkpointID, step: step))
                            }
                        )
                        // A `.approve`/`.edit` resume means the host
                        // already executed the side effect — the loop
                        // is just generating a wrap-up message at this
                        // point. Flag that so a guardrail trip or
                        // similar generative hiccup doesn't downgrade
                        // a successful action into a "Run failed".
                        let isPostApprove = approval.map { approval in
                            switch approval {
                            case .approve, .edit: true
                            case .reject: false
                            }
                        } ?? false
                        try await self.drive(
                            agent: agent,
                            input: .message(.user(nudge)),
                            runID: record.id,
                            sink: sink,
                            isPostApprove: isPostApprove,
                            continuation: continuation
                        )
                    } catch {
                        continuation.yield(.failed(Self.describe(error)))
                        continuation.finish()
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        // MARK: Private

        private let chatHistory: any ChatHistory
        private let compiler: AgentCompiler

        /// Friendly error text for `.failed` events + `outputSummary`.
        /// `AgentError` doesn't conform to `LocalizedError`, so the
        /// default `error.localizedDescription` collapses to
        /// "Aria.AgentError error 0". Unwrap to surface the real
        /// reason (provider failure detail, tool name + cause, etc.).
        private static func describe(_ error: any Error) -> String {
            guard let agentError = error as? AgentError else {
                return error.localizedDescription
            }
            switch agentError {
            case let .providerFailed(message, underlying):
                if let underlying {
                    return "Provider failed: \(message) — \(Self.condense(underlying.message))"
                }
                return "Provider failed: \(message)"
            case let .toolNotFound(name):
                return "Tool not found: \(name)"
            case let .toolExecutionFailed(toolName, underlying):
                return "Tool \(toolName) failed: \(Self.condense(underlying.message))"
            case let .maxStepsReached(steps):
                return "Reached max steps (\(steps))"
            case let .invalidToolArguments(toolName, reason):
                return "Bad arguments for \(toolName): \(reason)"
            case .cancelled:
                return "Cancelled."
            case let .timeout(duration):
                return "Timed out after \(duration)"
            case let .malformedProviderEvent(detail):
                return "Malformed provider event: \(detail)"
            case let .configurationInvalid(detail):
                return "Configuration error: \(detail)"
            }
        }

        /// NSError descriptions cascade verbosely with " UserInfo={…}"
        /// dumps that aren't useful in the UI. Keep just the head (the
        /// localized cause), cap length, and tack on a known-issue
        /// hint when we recognize a common cause so users understand
        /// what to try next.
        private static func condense(_ message: String) -> String {
            let head = message.components(separatedBy: " UserInfo=").first ?? message
            let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = trimmed.count <= 220
                ? trimmed
                : String(trimmed.prefix(220)) + "…"
            if let hint = Self.knownIssueHint(in: message) {
                return summary + "\n\n" + hint
            }
            return summary
        }

        /// Map known SDK-side noise to a one-line "what to try" hint.
        /// The most common one today is FoundationModels' on-device
        /// safety classifier failing to decode `thoughtContents` on
        /// some iOS 26 simulator runtimes — the underlying NSError
        /// surfaces "SensitiveContentAnalysisML". Usually transient.
        private static func knownIssueHint(in message: String) -> String? {
            if message.contains("SensitiveContentAnalysisML") || message.contains("thoughtContents") {
                return "Apple's on-device safety classifier hiccuped — usually transient. Tap Try again, or pick a server LLM for this agent."
            }
            return nil
        }

        private static func resumeNudge(
            record: AgentRunRecord,
            approval: ApprovalResolution?
        ) -> String {
            guard let approval, let proposal = record.pendingProposal else {
                return "Continue."
            }
            switch approval {
            case .approve, .edit:
                // Constrained nudge — the open-ended "Continue or
                // finish" let the model re-narrate the entire plan
                // it already proposed pre-approval (it had nothing
                // new to say, so it just repeated itself). Forcing
                // a short acknowledgment + STOP gives a clean
                // single confirmation line in the UI.
                return """
                The user approved your proposed action "\(proposal.title)" and the app already carried it out.
                Reply with ONE short confirmation sentence (e.g. "Done — scheduled 4 reminders.") and STOP.
                Do NOT re-describe the plan, do NOT re-list the items, do NOT call any more tools.
                """
            case .reject:
                return """
                The user rejected your proposed action "\(proposal.title)".
                Acknowledge in ONE short sentence (e.g. "Understood — not scheduling those.") and STOP.
                Do NOT attempt the action again.
                """
            }
        }

        private func drive(
            agent: Agent,
            input: AgentInput,
            runID: UUID,
            sink: AgentApprovalSink,
            isPostApprove: Bool,
            continuation: AsyncThrowingStream<AgentRunEvent, any Error>.Continuation
        ) async throws {
            print("[AGENT] drive START runID=\(runID) isPostApprove=\(isPostApprove)")
            var output = ""
            var finishReason: FinishReason = .endTurn
            do {
                for try await event in agent.stream(input) {
                    switch event {
                    case .userMessageReceived:
                        print("[AGENT] event userMessageReceived")
                    case let .stepStart(index):
                        print("[AGENT] event stepStart index=\(index)")
                        continuation.yield(.stepStart(index))
                    case .assistantStart:
                        print("[AGENT] event assistantStart")
                        continuation.yield(.assistantStart)
                    case let .textDelta(delta):
                        output += delta
                        continuation.yield(.textDelta(delta))
                    case let .toolCallRequested(call):
                        print("[AGENT] event toolCallRequested name=\(call.name) id=\(call.id) args=\(call.arguments)")
                        continuation.yield(.toolCallRequested(call))
                    case let .toolExecutionStart(callId):
                        print("[AGENT] event toolExecutionStart callId=\(callId)")
                        continuation.yield(.toolExecutionStart(callId: callId))
                    case let .toolExecutionEnd(callId, result):
                        print(
                            "[AGENT] event toolExecutionEnd callId=\(callId) isError=\(result.isError) output=\(result.output)"
                        )
                        continuation.yield(.toolExecutionEnd(callId: callId, result: result))
                    case let .stepEnd(index):
                        print("[AGENT] event stepEnd index=\(index) sinkHasProposal=\(sink.proposal != nil)")
                        continuation.yield(.stepEnd(index))
                    case let .finish(reason):
                        print("[AGENT] event finish reason=\(reason)")
                        finishReason = reason
                    case let .error(error):
                        print("[AGENT] event error \(error)")
                        throw error
                    }
                }
            } catch {
                // Cancellation has different semantics from a
                // genuine model / tool failure. The consumer
                // has already torn down the AsyncThrowingStream
                // (the `task.cancel()` in `onTermination` is what
                // typically caused this), so yielding `.failed`
                // would land on a dead continuation. Boot-time
                // `recoverOrphanedRuns` will clean up any
                // record still stuck in `.running` next launch.
                if error is CancellationError {
                    print("[AGENT] drive CANCELLED runID=\(runID) — leaving rescue paths untouched")
                    return
                }
                // Sink-first: if a proposal was already recorded
                // before the stream errored (e.g. FoundationModels
                // guardrail trips on the post-propose wrap-up text),
                // the agentic contract is satisfied — the model
                // made its call. Honor the proposal rather than
                // waste it on a generative hiccup. Without this,
                // the user sees "Run failed" with no way to approve
                // a perfectly good proposal that was already in the
                // sink.
                let hasProposal = sink.proposal != nil
                print("[AGENT] drive CAUGHT error=\(Self.describe(error)) hasProposal=\(hasProposal)")
                if let proposal = sink.proposal {
                    print("[AGENT] drive RESCUE proposal-after-error kind=\(proposal.kind)")
                    _ = try? self.runStore.update(id: runID) { row in
                        row.status = .awaitingApproval
                        row.pendingProposal = proposal
                    }
                    continuation.yield(.awaitingApproval(proposal))
                    continuation.finish()
                    return
                }
                // Post-approve rescue: when the resume after `.approve`
                // / `.edit` errors out, the host already executed the
                // side effect — only the cosmetic wrap-up text failed.
                // Treat as success rather than failure so the user
                // doesn't see "Run failed" for an action that actually
                // landed.
                if isPostApprove {
                    print("[AGENT] drive RESCUE post-approve generative error swallowed")
                    _ = try? self.runStore.update(id: runID) { row in
                        row.status = .completed
                        if (row.outputSummary ?? "").isEmpty {
                            row.outputSummary = "Action carried out."
                        }
                    }
                    continuation.yield(.finished(reason: .endTurn, output: "Done."))
                    continuation.finish()
                    return
                }
                _ = try? self.runStore.update(id: runID) { row in
                    row.status = .failed
                    row.outputSummary = Self.describe(error)
                }
                continuation.yield(.failed(Self.describe(error)))
                continuation.finish()
                return
            }
            print(
                "[AGENT] drive stream-end finishReason=\(finishReason) sinkHasProposal=\(sink.proposal != nil) outputLen=\(output.count)"
            )
            if let proposal = sink.proposal {
                print("[AGENT] drive PARK awaitingApproval kind=\(proposal.kind)")
                _ = try? self.runStore.update(id: runID) { row in
                    row.status = .awaitingApproval
                    row.pendingProposal = proposal
                }
                continuation.yield(.awaitingApproval(proposal))
                continuation.finish()
                return
            }
            print("[AGENT] drive FINISH completed")
            _ = try? self.runStore.update(id: runID) { row in
                row.status = .completed
                row.outputSummary = output
            }
            continuation.yield(.finished(reason: finishReason, output: output))
            continuation.finish()
        }
    }

    // MARK: - AgentRuntimeError

    public enum AgentRuntimeError: Error, Sendable, Equatable {
        case agentNotFound(UUID)
        case runNotFound(UUID)
    }

#endif
