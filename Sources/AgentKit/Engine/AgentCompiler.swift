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

            let middleware: [any AgentMiddleware] = [
                HistoryMiddleware(history: history),
                HistoryWindowMiddleware(maxTurns: Self.windowMaxTurns, maxTokens: Self.windowMaxTokens),
                CheckpointMiddleware(
                    checkpointer: self.checkpointer,
                    runID: runID,
                    runStore: self.runStore,
                    onCheckpoint: onCheckpoint
                ),
                RecordingMiddleware(recorder: recorder),
            ]

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

        /// `Current date: YYYY-MM-DD. Current time: HH:MM <tz>.`
        /// Pinned at compile time (right when the agent boots
        /// to handle a turn) so it reflects the moment the user
        /// asked, not the moment the bundle shipped.
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
            return """
            Current date: \(dateFormatter.string(from: now)) (\(timeFormatter.string(from: now)) \(TimeZone.current
                .identifier))
            Current ISO-8601 instant: \(iso.string(from: now))
            When you emit ISO-8601 datetimes, base them on the values above. Never schedule anything for a date in the past.
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
