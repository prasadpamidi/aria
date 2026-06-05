import Aria
import Foundation
import WorkflowKit

#if canImport(FoundationModels)
    import AriaApple
    import FoundationModels
#endif

#if canImport(FoundationModels)

    // MARK: - AgentCompiler

    /// Lowers an `AgentDefinition` into a runnable `Aria.Agent`. App-
    /// agnostic: capabilities, skills, the propose tool, checkpointing,
    /// and the run lifecycle are handled here, while everything app-
    /// specific is injected as two closures:
    ///
    ///   - `extraTools` — the host's MCP / workflow / plugin / skill-load
    ///     tools as `FoundationModelsToolKit`s.
    ///   - `makeProvider` — the host's LLM routing (FoundationModels /
    ///     MLX / server). `AgentProviders.foundationModelsOnly` is a
    ///     ready default.
    ///
    /// This mirrors how `WorkflowCompiler` takes resolver protocols and
    /// lets each app (avyra, niora) supply its own wiring.
    @available(iOS 26.0, macOS 26.0, *)
    @MainActor
    struct AgentCompiler {
        // MARK: Internal

        let broker: CapabilityBroker
        let skillProvider: SkillProvider?
        let checkpointer: any Checkpointer
        let runStore: AgentRunStore
        let extraTools: AgentExtraToolsProvider
        let extraMiddleware: AgentExtraMiddlewareProvider
        let makeProvider: AgentProviderFactory

        func compile(
            definition: AgentDefinition,
            runID: UUID,
            threadId: String,
            history: any ChatHistory,
            recorder: SessionRecorder,
            attended: Bool,
            approvalSink: AgentApprovalSink,
            onCheckpoint: @escaping @Sendable (_ checkpointID: String, _ step: Int) -> Void
        ) -> Agent {
            var kits = CapabilityToolKitBuilder.makeKits(
                for: definition,
                broker: self.broker,
                attended: attended
            )
            kits.append(contentsOf: self.extraTools(definition))
            if case let .proposeThenConfirm(actions) = definition.approvalPolicy {
                kits.append(ProposeToolKitBuilder.makeKit(sink: approvalSink, allowedKinds: actions))
            }

            let systemPrompt = self.systemPrompt(for: definition)
            let provider = self.makeProvider(definition, kits.map(\.factory), systemPrompt)
            let tools = provider.capabilities.supportsToolUse ? kits.map(\.anyTool) : []

            // Extras are inserted between HistoryMiddleware and
            // HistoryWindowMiddleware so summarization sees the full
            // loaded history before the window cap engages. RAG +
            // fact-extraction don't care about positioning (their hooks
            // are time-based not state-pipeline-based), but summarization
            // strictly does — it has to compress older turns BEFORE the
            // window middleware drops them.
            var middleware: [any AgentMiddleware] = [HistoryMiddleware(history: history)]
            middleware.append(contentsOf: self.extraMiddleware(definition))
            middleware.append(contentsOf: [
                HistoryWindowMiddleware(maxTurns: Self.windowMaxTurns, maxTokens: Self.windowMaxTokens),
                CheckpointMiddleware(
                    checkpointer: self.checkpointer,
                    runID: runID,
                    runStore: self.runStore,
                    onCheckpoint: onCheckpoint
                ),
                RecordingMiddleware(recorder: recorder),
            ])

            return Agent(config: AgentConfig(
                provider: provider,
                tools: tools,
                systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                threadId: threadId,
                middleware: middleware,
                maxSteps: definition.maxSteps
            ))
        }

        // MARK: Private

        /// Conservative budget — FoundationModels caps near 4096 tokens.
        private static let windowMaxTurns = 24
        private static let windowMaxTokens = 3000

        /// Stamped at the top of every system prompt right when
        /// the agent boots to handle a turn so it reflects the
        /// moment the user asked, not the moment the bundle
        /// shipped. The block is deliberately verbose about
        /// timezone semantics — small on-device LLMs were
        /// observed emitting `fireAt` strings ending in `Z`
        /// (UTC) even when the prompt clearly stated the local
        /// timezone, which shifts the scheduled fire time by
        /// the UTC offset (e.g. `18:00Z` fires at 11am local in
        /// `America/Los_Angeles`). The anchor now teaches the
        /// model two safe shapes — naïve ISO (no `Z`, no offset
        /// → host parses as local) and offset-bearing ISO using
        /// the EXACT string shown — and explicitly bans `Z`.
        private static func currentDateAnchor() -> String {
            let now = Date()
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.timeZone = TimeZone.current
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm"
            timeFormatter.locale = Locale(identifier: "en_US_POSIX")
            timeFormatter.timeZone = TimeZone.current
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            iso.timeZone = TimeZone.current
            let naive = DateFormatter()
            naive.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            naive.locale = Locale(identifier: "en_US_POSIX")
            naive.timeZone = TimeZone.current

            let nowLocal = naive.string(from: now)
            let nowOffset = iso.string(from: now)
            let plusOneHour = naive.string(from: now.addingTimeInterval(3600))
            let tzID = TimeZone.current.identifier

            return """
            Current date: \(dateFormatter.string(from: now)) (\(timeFormatter.string(from: now)) \(tzID))
            Current local datetime: \(nowLocal)
            Current ISO-8601 instant (with offset): \(nowOffset)

            When you emit a datetime (e.g. `fireAt` for a reminder/notification), use ONE of these shapes:

              1. Local naïve datetime, no timezone suffix — the host interprets it in \(tzID).
                 Example: one hour from now is exactly `\(plusOneHour)`.
              2. ISO-8601 with the EXACT offset shown above — copy the suffix from the line above verbatim.
                 Example: right now is `\(nowOffset)`.

            DO NOT append `Z` to a datetime. `Z` means UTC and will fire at the wrong wall-clock time. \
            DO NOT invent a different offset (e.g. `+00:00`, `-05:00`) unless the user explicitly asks for it.
            Never schedule anything for a date or time in the past.
            """
        }

        /// Persona + date anchor + inline skill bodies. Date
        /// anchor is prepended because small on-device models
        /// can't reliably ground in the current date on their
        /// own — observed cases where agents emitted ISO
        /// timestamps from years prior because the prompt only
        /// said "compute real ISO-8601 datetimes from the
        /// current date" without giving them WHAT that date is.
        /// One-line `Current date / time` header at the top
        /// gives every downstream "schedule X for tomorrow"
        /// instruction something to compute against.
        ///
        /// The loadable skill tool for non-inline skills is the
        /// host's job via `extraTools`.
        private func systemPrompt(for definition: AgentDefinition) -> String {
            let dateAnchor = Self.currentDateAnchor()
            let skillBlock = self.skillsBlock(for: definition)
            let pieces: [String] = [dateAnchor, definition.systemPrompt, skillBlock]
                .filter { !$0.isEmpty }
            return pieces.joined(separator: "\n\n")
        }

        private func skillsBlock(for definition: AgentDefinition) -> String {
            guard let skillProvider = self.skillProvider, !definition.enabledSkillIDs.isEmpty else {
                return ""
            }
            return SkillPromptBuilder.systemPromptBlock(
                provider: skillProvider,
                allowedSkillIDs: definition.enabledSkillIDs
            )
        }
    }

#endif
