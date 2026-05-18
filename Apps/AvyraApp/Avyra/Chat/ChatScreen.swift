import Aria
import AriaApple
import OSLog
import PhotosUI
import SwiftUI

#if canImport(AriaMLX)
    import AriaMLX
#endif
#if canImport(FoundationModels)
    import FoundationModels
#endif

// MARK: - Logging

/// Common channel for chat-flow diagnostics. Tail with:
///
///     log stream --predicate 'subsystem == "com.3theories.app.Avyra" \
///         && category == "Chat"' --level debug
///
/// `nonisolated` because the project defaults to `MainActor`
/// isolation, and we want this readable from any actor (the smoother
/// drain task, async stream loops, etc.).
private nonisolated let chatLog = Logger(
    subsystem: "com.3theories.app.Avyra",
    category: "Chat"
)

// MARK: - ChatScreen

/// The chat surface — message list, input bar, optional image
/// attachment, recall badge. Extracted from the prior monolithic
/// `ContentView` so it's just the chat: demos / memories / settings
/// live in their own tabs.
///
/// Settings (memory on/off, summarization config, window caps, RAG
/// top-K) come from `@Environment(\.avyraSettings)` and re-read on
/// every agent build — so toggling a knob in Settings shows up on the
/// next chat turn with no manual refresh.
struct ChatScreen: View {
    // MARK: Lifecycle

    init(
        storage: GRDBStorage,
        appState: AppState,
        sessionRecorder: SessionRecorder
    ) {
        self.storage = storage
        self.appState = appState
        self.sessionRecorder = sessionRecorder
    }

    // MARK: Internal

    var body: some View {
        NavigationStack {
            self.messageList
                // Bottom safe area hosts the model-loading pill
                // (when warming up), quick-action chips (empty chat
                // only), and the input bar. SwiftUI auto-insets the
                // scroll content above the whole strip AND lifts it
                // above the keyboard on focus.
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 0) {
                            ModelStatusPill(status: self.modelStatus)
                                .animation(.snappy, value: self.modelStatus)
                            if self.transcript.isEmpty {
                                QuickActionChips(
                                    prompts: QuickActionChips.starterPrompts,
                                    isStreaming: self.isStreaming,
                                    onPick: { prompt in
                                        self.input = prompt
                                        self.inputFocused = true
                                    }
                                )
                            }
                            self.inputBar
                        }
                    }
                    .background(self.chatBackground)
                    // Native nav-bar toolbar — gets iOS's scroll-edge
                    // blur, automatic safe-area + keyboard avoidance for
                    // free. Items are inline (no large title) and the
                    // background is clear so the chat gradient shows
                    // through.
                    .toolbar { self.toolbarContent }
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.clear, for: .navigationBar)
        }
        .sheet(isPresented: self.$modelPickerShown) {
            ModelPickerSheet(appState: self.appState) {
                self.modelPickerShown = false
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: self.$settingsSheetShown) {
            NavigationStack {
                SettingsScreen(
                    storage: self.storage,
                    appState: self.appState,
                    sessionRecorder: self.sessionRecorder,
                    activeThreadId: self.currentThreadId,
                    onLoadThread: { threadId in
                        Task { await self.loadThread(threadId) }
                    }
                )
            }
        }
        // The "warm the model on chat appear" task lived here but
        // caused two bugs: (a) it shared the same swift-huggingface
        // call path that hangs mid-load on flaky networks, so the
        // pill stayed up forever; (b) the locked container blocked
        // any subsequent `streamWithAgent` from running, so the
        // user couldn't chat. `streamWithAgent` already shows the
        // warmup pill on first message and clears it on first
        // textDelta — that's the right place to gate the wait.
    }

    // MARK: Private

    /// Cap on a single turn's attachments. Vision models accept more
    /// in theory, but the input strip stays readable at ≤6 and the
    /// model context fills fast past that.
    private static let maxAttachments = 6

    #if canImport(FoundationModels)
        /// First-token timeout. If the agent doesn't produce a single
        /// `.textDelta` or `.toolCallRequested` event in this many
        /// seconds we cancel the stream and surface an error — the
        /// alternative is leaving the user staring at "Loading
        /// Gemma…" indefinitely when the MLX model load (via
        /// swift-huggingface) wedges. 90 s comfortably covers cold
        /// loads of 4-8 GB models on a recent device; anything
        /// longer is almost certainly a stuck SDK call.
        @available(iOS 26.0, macOS 26.0, *)
        private static let firstTokenTimeout: Duration = .seconds(90)

        @MainActor
        private func streamWithAgent(userMessage: Message) async {
            chatLog
                .info(
                    "[Avyra/Chat] turn start provider=\(self.providerLabel, privacy: .public) needsWarmup=\(self.providerNeedsWarmupPill)"
                )
            let agent = self.makeAgent()
            chatLog.debug("[Avyra/Chat] agent built")
            // Show a "Loading <model>…" pill while the provider warms
            // up — meaningful for MLX (multi-GB weights decompress
            // from disk on first use) and harmless for
            // FoundationModels (cleared the instant the first token
            // arrives, which is essentially immediate there).
            self.modelStatus = self.providerNeedsWarmupPill
                ? .preparing(label: self.providerLabel)
                : .ready
            defer {
                self.modelStatus = .ready
                chatLog.info("[Avyra/Chat] turn end — modelStatus cleared")
                // Make sure nothing is stuck in the smoother on early
                // exit (cancellation, error, etc.) — the bubble
                // should always end matching the provider's final
                // text. `flush` is a no-op if `pending` is empty.
                self.streamer.flush()
            }
            // Fresh streamer state per turn — `.reset()` cancels the
            // drain task, clears `displayed`, and starts the next
            // turn from a known-empty buffer.
            self.streamer.reset()
            // Race the stream against a first-token timer. The
            // timer fires `withTaskCancellationHandler` into the
            // stream Task when it expires.
            await self.runStreamWithFirstTokenTimeout(
                agent: agent,
                userMessage: userMessage
            )
        }

        /// Wraps the agent stream in a `TaskGroup` that races the
        /// stream against a timeout. The timer is cancelled the
        /// moment the first content event lands; if it fires first,
        /// we cancel the stream and surface a friendly timeout
        /// error so the user can retry.
        @available(iOS 26.0, macOS 26.0, *)
        @MainActor
        private func runStreamWithFirstTokenTimeout(
            agent: Agent,
            userMessage: Message
        ) async {
            let timeout = Self.firstTokenTimeout
            chatLog.debug("[Avyra/Chat] watchdog start timeout=\(timeout) (first-event only)")
            // Watchdog only fires if NO event arrives within
            // `firstTokenTimeout`. Reasoning models like Qwen 3.5
            // can stay in their thinking phase for minutes, but
            // they emit `.textDelta` events the entire time —
            // those reset the watchdog so it never wrongly
            // triggers mid-thinking. The previous design raced
            // the timer against the *whole turn finishing*, which
            // produced a false-positive every Qwen turn that took
            // longer than 90s end-to-end.
            let sentinel = FirstEventSentinel()
            let consumeTask = Task { @MainActor in
                await self.consumeAgentStream(
                    agent: agent,
                    userMessage: userMessage,
                    onFirstEvent: {
                        Task { await sentinel.markSeen() }
                    }
                )
            }
            let watchdog = Task { [providerLabel = self.providerLabel] in
                try? await Task.sleep(for: timeout)
                if await sentinel.wasSeen {
                    // Events flowing — let the stream run to
                    // completion at its own pace.
                    return
                }
                chatLog.error("[Avyra/Chat] no first event in \(timeout) — cancelling stream")
                consumeTask.cancel()
                await MainActor.run {
                    self.streamer.flush()
                    self.setErrorOnLastAssistant(
                        AssistantError(
                            friendly: "The model is taking too long to load.",
                            hint: "Tap the new-chat button and try again — if it keeps happening, switch to a smaller model from Manage models.",
                            technical: "ChatScreen first-event watchdog fired after \(timeout) for \(providerLabel)"
                        )
                    )
                }
            }
            await consumeTask.value
            watchdog.cancel()
        }

        /// Drains the agent's event stream into the smoother +
        /// transcript. Reports whether it completed naturally — the
        /// timeout leg compares against this to know if it should
        /// surface an error.
        @available(iOS 26.0, macOS 26.0, *)
        @MainActor
        private func consumeAgentStream(
            agent: Agent,
            userMessage: Message,
            onFirstEvent: @escaping () -> Void = { }
        ) async {
            let startedAt = Date()
            var sawFirstEvent = false
            var eventCount = 0
            chatLog.debug("[Avyra/Chat] stream open — awaiting first event")
            do {
                for try await event in agent.stream(.message(userMessage)) {
                    if Task.isCancelled {
                        chatLog.notice("[Avyra/Chat] stream cancelled after \(eventCount) events")
                        return
                    }
                    eventCount += 1
                    if !sawFirstEvent {
                        sawFirstEvent = true
                        onFirstEvent()
                        let waited = Date().timeIntervalSince(startedAt)
                        chatLog
                            .info(
                                "[Avyra/Chat] first event after \(String(format: "%.2f", waited))s kind=\(Self.eventKind(event), privacy: .public)"
                            )
                        // Mark the active MLX model as warmed up so
                        // the next turn skips the "Loading…" pill.
                        // First-event time IS the proxy for "the
                        // container is now in MLXModelStore's cache."
                        #if canImport(AriaMLX)
                            if let active = self.appState.modelManager.activeCapabilities {
                                self.warmedUpModelIds.insert(active.id)
                            }
                        #endif
                    }
                    switch event {
                    case let .textDelta(chunk):
                        self.modelStatus = .ready
                        self.streamer.append(chunk)
                    case let .toolCallRequested(call):
                        chatLog.debug("[Avyra/Chat] tool call \(call.name, privacy: .public)")
                        self.modelStatus = .ready
                        self.appendToolCallToLastAssistant(name: call.name)
                    case .finish:
                        let total = Date().timeIntervalSince(startedAt)
                        chatLog
                            .info(
                                "[Avyra/Chat] stream finished events=\(eventCount) in \(String(format: "%.1f", total))s"
                            )
                        return
                    case let .error(err):
                        chatLog.error("[Avyra/Chat] stream error event \(String(describing: err), privacy: .public)")
                        // Provider gave up mid-stream. Drain whatever
                        // partial text it produced, then attach a
                        // friendly error so the bubble can swap to
                        // its `ErrorCard` layout. The raw dump is
                        // preserved for developer mode.
                        self.streamer.flush()
                        self.setErrorOnLastAssistant(.from(err))
                        return
                    default:
                        break
                    }
                }
                let total = Date().timeIntervalSince(startedAt)
                chatLog
                    .notice(
                        "[Avyra/Chat] stream loop exited cleanly without .finish events=\(eventCount) in \(String(format: "%.1f", total))s"
                    )
                return
            } catch is CancellationError {
                chatLog.notice("[Avyra/Chat] stream cancelled (timeout or external) after \(eventCount) events")
                // Stream was cancelled by the watchdog — it
                // surfaces the friendly error; don't add a second.
                return
            } catch {
                chatLog.error("[Avyra/Chat] stream threw \(error.localizedDescription, privacy: .public)")
                self.streamer.flush()
                self.setErrorOnLastAssistant(.from(error))
                return
            }
        }

        /// Short label for one event — for log lines.
        private static func eventKind(_ event: AgentEvent) -> String {
            switch event {
            case .textDelta: "textDelta"
            case .toolCallRequested: "toolCallRequested"
            case .finish: "finish"
            case .error: "error"
            default: "other"
            }
        }

        /// Only large-model providers need the warmup pill — fast
        /// providers (FoundationModels) reach first-token before the
        /// pill could even animate in, so suppressing it for them
        /// avoids a flash of UI for nothing.
        ///
        /// AND — only on the *cold* turn. `MLXModelStore` caches the
        /// loaded `ModelContainer` after first use, so the 2nd+ turn
        /// for the same model id reaches first-token in ~milliseconds.
        /// Showing the pill there flashes briefly and reads as broken.
        /// We track per-session warmed model ids and skip the pill
        /// once a model has produced its first event.
        /// Heuristic: the active MLX model is a reasoning model that
        /// streams its chain-of-thought before the final reply.
        /// Today that's Qwen 3.x (any variant) and a few research
        /// fine-tunes; expand the prefix list when we add more.
        /// FoundationModels and standard instruct models return
        /// `false` — they jump straight to the user-visible reply.
        private var activeModelIsReasoning: Bool {
            #if canImport(AriaMLX)
                guard let active = self.appState.modelManager.activeCapabilities else {
                    return false
                }
                let reasoningFamilyPrefixes = ["qwen3", "deepseek-r1"]
                let family = active.family.lowercased()
                return reasoningFamilyPrefixes.contains { family.hasPrefix($0) }
            #else
                return false
            #endif
        }

        private var providerNeedsWarmupPill: Bool {
            #if canImport(AriaMLX)
                guard let active = self.appState.modelManager.activeCapabilities else {
                    return false
                }
                return !self.warmedUpModelIds.contains(active.id)
            #else
                return false
            #endif
        }

        // `prewarmActiveModelIfNeeded` removed — see body comment.
        // The first message's stream handles model loading via the
        // warmup pill in `streamWithAgent`, which clears reliably in
        // its `defer` block.

        @available(iOS 26.0, macOS 26.0, *)
        private func makeAgent() -> Agent {
            let memory = self.settings.memoryEnabled ? self.makeMemoryStore() : nil
            let middlewares = self.makeMiddleware(memory: memory)
            var kits: [FoundationModelsToolKit] = [
                registerFoundationModelsTool(CurrentTimeTool()),
            ]
            if let memory {
                kits.append(registerFoundationModelsTool(
                    RememberTool(memoryStore: memory, namespace: AvyraConstants.memoryNamespace)
                ))
            }
            let provider: any LLMProvider = self.makeProvider(kits: kits)
            let toolsForAgent = provider.capabilities.supportsToolUse
                ? kits.map(\.anyTool)
                : []
            // Capture custom instructions once so the same string
            // flows to AgentConfig.systemPrompt AND the provider's
            // defaultInstructions — both need them so the user's
            // persona/preferences apply whether the agent assembles
            // the prompt itself or the provider has to.
            let customInstructions = self.settings.customInstructions
            return Agent(config: AgentConfig(
                provider: provider,
                tools: toolsForAgent,
                systemPrompt: Self.systemPrompt(
                    memoryEnabled: memory != nil,
                    customInstructions: customInstructions
                ),
                threadId: self.currentThreadId,
                middleware: middlewares
            ))
        }

        @available(iOS 26.0, macOS 26.0, *)
        private func makeProvider(kits: [FoundationModelsToolKit]) -> any LLMProvider {
            let customInstructions = self.settings.customInstructions
            #if canImport(AriaMLX)
                if let mlx = self.appState.modelManager.makeProvider(
                    defaultInstructions: Self.systemPrompt(
                        memoryEnabled: false,
                        customInstructions: customInstructions
                    )
                ) {
                    return mlx
                }
            #endif
            return FoundationModelsProvider(typedTools: kits.map(\.factory))
        }

        private func makeMemoryStore() -> (any MemoryStore)? {
            guard let embedder = NLEmbeddingEmbedder() else {
                return nil
            }
            let store = self.storage.vectorStore(dimensions: embedder.dimensions)
            return DefaultMemoryStore(embedder: embedder, store: store)
        }

        /// Builds the middleware chain off `AvyraSettings`. Every knob
        /// the user can flip in the Settings tab is reflected here on
        /// the next agent build:
        ///   1. `HistoryMiddleware` — always on (chat without history
        ///      is uninteresting)
        ///   2. `HistorySummarizationMiddleware` — gated on
        ///      `summarizationEnabled`, sized by trigger / keep knobs
        ///   3. `HistoryWindowMiddleware` — always on, sized by
        ///      window knobs
        ///   4. `RAGMiddleware` — only when memory is enabled
        ///   5. `FactExtractionMiddleware` — gated on both
        ///      `memoryEnabled` and `factExtractionEnabled`
        ///   6. `RecordingMiddleware` — always on (the "Share
        ///      session" affordance in Settings reads from here)
        private func makeMiddleware(memory: (any MemoryStore)?) -> [any AgentMiddleware] {
            // When persistence is off, route history through the
            // app-scoped `InMemoryChatHistory` so the agent still has
            // cross-turn context within the session — only the GRDB
            // write is skipped. Past persisted threads remain readable
            // via Previous chats either way.
            let history: any ChatHistory = self.settings.persistConversationsEnabled
                ? self.storage.chatHistory
                : self.appState.ephemeralHistory
            var middlewares: [any AgentMiddleware] = [
                HistoryMiddleware(history: history),
            ]
            #if canImport(FoundationModels)
                if #available(iOS 26.0, macOS 26.0, *), self.settings.summarizationEnabled {
                    middlewares.append(
                        HistorySummarizationMiddleware(
                            triggerAfterTurns: self.settings.summarizationTriggerTurns,
                            keepRecentTurns: self.settings.summarizationKeepRecentTurns,
                            summarizer: Self.summarizeMessages
                        )
                    )
                }
            #endif
            middlewares.append(
                HistoryWindowMiddleware(
                    maxTurns: self.settings.windowMaxTurns,
                    maxTokens: self.settings.windowMaxTokens
                )
            )
            if let memory {
                // Capture the inbox (a Sendable @Observable class), not
                // the view struct, so the @Sendable onRecall closure
                // doesn't have to reason about ChatScreen's transitive
                // stored properties (GRDB storage, recorders, etc.).
                let inbox = self.inbox
                middlewares.append(
                    RAGMiddleware(
                        memoryStore: memory,
                        namespace: AvyraConstants.memoryNamespace,
                        topK: self.settings.ragTopK,
                        onRecall: { matches in
                            let texts = matches.map(\.item.content)
                            Task { @MainActor in
                                inbox.pendingRecall = texts
                            }
                        }
                    )
                )
                #if canImport(FoundationModels)
                    if #available(iOS 26.0, macOS 26.0, *), self.settings.factExtractionEnabled {
                        middlewares.append(
                            FactExtractionMiddleware(
                                memory: memory,
                                namespace: AvyraConstants.memoryNamespace,
                                extractor: Self.extractFacts
                            )
                        )
                    }
                #endif
            }
            let recording = RecordingMiddleware(recorder: self.sessionRecorder)
            recording.bind(
                providerSystem: "apple.foundationmodels.default",
                providerModel: "apple.foundationmodels.default",
                systemPrompt: Self.systemPrompt(
                    memoryEnabled: memory != nil,
                    customInstructions: self.settings.customInstructions
                )
            )
            middlewares.append(recording)
            return middlewares
        }

        // MARK: - Auxiliary LLM helpers

        /// `nonisolated static` functions can be referenced as
        /// `@Sendable` values without conversion — the previous
        /// "factory returns a closure" pattern tripped Swift 6.2's
        /// caller-isolation inference at the middleware-init site.
        /// Passing `Self.summarizeMessages` directly skips the
        /// intermediate closure value entirely.
        @available(iOS 26.0, macOS 26.0, *)
        static nonisolated func summarizeMessages(_ messages: [Message]) async throws -> String {
            let serialized = messages.map { msg -> String in
                let role = msg.role == .user
                    ? "User"
                    : (msg.role == .assistant ? "Assistant" : "System")
                return "\(role): \(msg.textContent)"
            }.joined(separator: "\n\n")
            let prompt = """
            Summarize the conversation below in <=200 words, preserving:
            - durable user facts (preferences, goals, constraints, schedule)
            - decisions the assistant made
            - open threads / unresolved questions

            Return ONLY the summary text — no preamble, no headers, no markdown.

            Conversation:
            \(serialized)
            """
            return try await Self.runAuxiliaryCompletion(
                systemPrompt: "You are a precise conversation summarizer. Output only the summary.",
                userText: prompt
            )
        }

        @available(iOS 26.0, macOS 26.0, *)
        static nonisolated func extractFacts(_ message: Message) async throws -> [String] {
            // Stricter prompt to fix two issues we saw in
            // production:
            //
            //   1. **Subject contamination** — when the user asked
            //      "tell me about the Eiffel Tower," the model
            //      extracted Eiffel Tower facts as if they were
            //      user facts.
            //   2. **Over-extraction** — even simple questions
            //      produced entries when none should have.
            //
            // Fix: hard-restrict to FIRST-PERSON statements about
            // the user themselves, give crisp positive AND negative
            // examples covering the failure mode, and bias the
            // model toward returning `[]` when in doubt.
            let prompt = """
            You extract DURABLE FACTS ABOUT THE USER from one chat message.

            Rules:
            - ONLY extract facts the user said about THEMSELVES, in first person.
            - Look for "I am / I have / I prefer / I work as / I live in / my X is …".
            - SKIP general world knowledge, definitions, history, places, people.
            - SKIP what the user is ASKING about — questions don't establish user facts.
            - SKIP transient state (feelings, what they're doing right now).
            - When in doubt, return [].

            Good examples (user stated about themselves):
              "I prefer metric units"     → ["user prefers metric units"]
              "I'm vegetarian"            → ["user is vegetarian"]
              "I work as a chef"          → ["user works as a chef"]
              "Remember I'm in Berlin"    → ["user lives in Berlin"]

            Bad examples (DO NOT extract):
              "Tell me about the Eiffel Tower"       → []   (a question)
              "What's the capital of France?"        → []   (a question)
              "The Eiffel Tower is in Paris"         → []   (world knowledge, not about user)
              "I'm feeling tired today"              → []   (transient state)
              "I want to know if dogs see in color"  → []   (curiosity, not a user fact)

            Return ONLY a JSON array of short fact strings, each beginning with "user ".
            Empty array if nothing durable. NO prose, NO markdown — JUST the array.

            Message: \(message.textContent)
            """
            let raw = try await Self.runAuxiliaryCompletion(
                systemPrompt: "You are a precise extractor of first-person user facts. Output only a JSON array of strings; empty when in doubt.",
                userText: prompt
            )
            let cleaned = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = cleaned.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [String] else {
                return []
            }
            // Belt-and-suspenders dedup-within-batch + format filter:
            // only keep strings that LOOK like user facts (start with
            // "user " after lowercasing) and aren't empty.
            var seen = Set<String>()
            return array.compactMap { rawFact -> String? in
                let trimmed = rawFact.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else {
                    return nil
                }
                guard trimmed.lowercased().hasPrefix("user ") else {
                    return nil
                }
                let key = trimmed.lowercased()
                guard seen.insert(key).inserted else {
                    return nil
                }
                return trimmed
            }
        }

        @available(iOS 26.0, macOS 26.0, *)
        private static func runAuxiliaryCompletion(
            systemPrompt: String,
            userText: String
        ) async throws -> String {
            let agent = Agent(config: AgentConfig(
                provider: FoundationModelsProvider(defaultInstructions: systemPrompt),
                tools: [],
                systemPrompt: systemPrompt,
                threadId: "aria-sample-aux-\(UUID().uuidString)"
            ))
            var accumulated = ""
            for try await event in agent.stream(.message(.user(userText))) {
                if case let .textDelta(text) = event {
                    accumulated += text
                }
            }
            return accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func systemPrompt(memoryEnabled: Bool, customInstructions: String = "") -> String {
            // Newline-separated sections so each instruction reads
            // as its own directive, not one long run-on sentence.
            // Custom instructions get a dedicated block at the
            // bottom with a visible heading the model latches onto
            // — putting them inline made FoundationModels and other
            // models treat them as flavor text rather than directives.
            var sections: [String] = [
                "You are Avyra, a concise, helpful assistant.",
                "Always use the tools you have access to when they are relevant; never describe a tool call in your reply text.",
            ]
            if memoryEnabled {
                sections.append(
                    "Save anything the user wants you to remember about themselves for future conversations."
                )
            }
            // User-authored "Custom instructions" from Settings →
            // Personalization. Set off with its own heading so the
            // model treats the contents as rules to follow, not
            // background context.
            let trimmedCustom = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCustom.isEmpty {
                sections.append(
                    "## Custom instructions from the user\n"
                        + "Follow these in every response. They take priority over default phrasing or tone choices — but never override safety guidelines.\n\n"
                        + trimmedCustom
                )
            }
            return sections.joined(separator: "\n\n")
        }

    #endif

    @State private var input: String = ""
    @State private var transcript: [TranscriptItem] = []
    @State private var isStreaming: Bool = false
    @State private var modelStatus: ModelStatus = .ready
    /// Set of MLX model ids whose container has been loaded at least
    /// once this app session. Used to suppress the "Loading…" pill
    /// on second-and-later turns — `MLXModelStore` caches the
    /// container after first use, so subsequent streams are
    /// instant and the pill is just noise.
    @State private var warmedUpModelIds: Set<String> = []
    /// `true` when the message list is scrolled enough above its
    /// bottom edge to warrant the floating "jump to latest" button.
    /// Driven by `onScrollGeometryChange` on the scroll view.
    @State private var isScrolledAwayFromBottom = false
    @State private var inbox = TranscriptInbox()
    /// Decouples raw provider deltas from on-screen rendering so the
    /// assistant bubble reads as a fluid typewriter instead of the
    /// burst-pause-burst that comes from binding `.textDelta` chunks
    /// directly to the view. See `SmoothTextStreamer` for the why.
    @State private var streamer = SmoothTextStreamer()
    @State private var pickedImages: [PhotosPickerItem] = []
    @State private var pendingImages: [Data] = []
    @State private var modelPickerShown = false
    @State private var settingsSheetShown = false
    /// The thread `HistoryMiddleware` reads from / writes to for the
    /// active conversation. Defaults to a fresh UUID per app launch so
    /// users land on an empty chat rather than the last session's
    /// transcript — past threads are reachable via Settings → Previous
    /// chats. `startNewChat()` mints a new id on demand.
    @State private var currentThreadId: String = UUID().uuidString
    @FocusState private var inputFocused: Bool

    @Environment(\.avyraSettings) private var settings

    private let storage: GRDBStorage
    private let appState: AppState
    private let sessionRecorder: SessionRecorder

    /// Persistent chat-level toolbar — the three controls a user
    /// needs while staring at the conversation:
    ///
    /// - **Settings (leading)** — gear icon; opens the consolidated
    ///   Settings sheet (which holds Memories, Demos, Previous chats,
    ///   plus middleware knobs).
    /// - **Model picker (center)** — friendly provider name in a
    ///   glass capsule; opens the in-chat model picker sheet.
    /// - **New chat (trailing)** — pencil-on-square; mints a fresh
    ///   thread id without nuking the persisted prior thread.
    ///
    /// All three disable while the agent is producing a response so
    /// the user can't yank the model out from under an in-flight turn.
    /// Native nav-bar toolbar. iOS handles the scroll-edge effect
    /// (background blur fades in as you scroll up under the bar),
    /// safe-area insetting, and keyboard avoidance for free — the
    /// previous custom `HStack` inside the message VStack had none
    /// of those wins.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            self.settingsButton
        }
        ToolbarItem(placement: .principal) {
            self.modelPill
        }
        ToolbarItem(placement: .topBarTrailing) {
            self.newChatButton
        }
    }

    /// A new chat is only meaningful if there's at least one message
    /// in the active thread — otherwise the button would just re-mint
    /// a thread id for an empty surface. Always disabled while
    /// streaming so the user can't snap a new thread mid-response.
    private var canStartNewChat: Bool {
        !self.isStreaming && !self.transcript.isEmpty
    }

    // MARK: - Subviews

    /// Short, user-friendly name for the active provider. Shown in
    /// the top toolbar's model pill — fits in ~24 characters so it
    /// doesn't truncate to gibberish like the previous version label.
    private var providerLabel: String {
        #if canImport(AriaMLX)
            if let capabilities = self.appState.modelManager.activeCapabilities {
                return capabilities.displayName
            }
        #endif
        return "Apple Intelligence"
    }

    private var sparklesGradient: LinearGradient {
        LinearGradient(
            colors: [Color.accentColor, Color.purple.opacity(0.8)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var remainingAttachmentSlots: Int {
        max(0, Self.maxAttachments - self.pendingImages.count)
    }

    private var canSend: Bool {
        if self.isStreaming {
            return false
        }
        let hasText = !self.input.trimmingCharacters(in: .whitespaces).isEmpty
        return hasText || !self.pendingImages.isEmpty
    }

    private var activeProviderSupportsVision: Bool {
        #if canImport(AriaMLX)
            if let entry = self.appState.modelManager.activeCapabilities {
                return entry.supportsVision
            }
        #endif
        return false
    }

    private var settingsButton: some View {
        Button {
            self.settingsSheetShown = true
        } label: {
            Image(systemName: "gearshape")
                .foregroundStyle(self.isStreaming ? .tertiary : .primary)
                .glassEffect(.regular, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(self.isStreaming)
        .accessibilityLabel("Settings")
    }

    /// Model picker pill — glass capsule that stretches between the
    /// two 52pt buttons. `minimumScaleFactor` + `layoutPriority` let
    /// a long provider name shrink to fit rather than truncate;
    /// without the layout priority the HStack gives the text its
    /// intrinsic width and truncation kicks in before scaling does.
    private var modelPill: some View {
        Button {
            self.modelPickerShown = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.subheadline)
                Text(self.providerLabel)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                    .layoutPriority(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(self.isStreaming ? .tertiary : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Capsule())
            .glassEffect(.regular, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(self.isStreaming)
        .accessibilityLabel("Pick model")
    }

    private var newChatButton: some View {
        Button {
            self.startNewChat()
        } label: {
            Image(systemName: "square.and.pencil")
                .glassEffect(.regular, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!self.canStartNewChat)
        .accessibilityLabel("New chat")
    }

    /// Page background — system fill underneath, with a soft accent
    /// gradient washed on top so light and dark modes both pick up a
    /// tint without the chat surface feeling clinical. The accent +
    /// purple pair echoes the assistant-avatar gradient so the bubble
    /// reads as belonging to the surface, not floating on it.
    private var chatBackground: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.22),
                    Color.purple.opacity(0.14),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottom
            )
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.accentColor.opacity(0.08),
                ],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if self.transcript.isEmpty {
                        self.emptyState
                            .animation(.smooth(duration: 0.28), value: self.inputFocused)
                    } else {
                        let lastIndex = self.transcript.count - 1
                        ForEach(Array(self.transcript.enumerated()), id: \.element.id) { index, item in
                            MessageBubble(
                                item: item,
                                isFirstInGroup: self.isFirstInGroup(at: index)
                            )
                            .id(item.id)
                            // Watch the *last* message's visibility
                            // as the single source of truth for
                            // "is the user at the bottom?" — way
                            // more reliable than the previous
                            // sentinel-below approach, where
                            // `scrollTo(last, .bottom)` positions
                            // the last bubble at the visible
                            // bottom and the sentinel sits
                            // off-screen, so the button never
                            // hid. Threshold 0.25 means as soon as
                            // ~quarter of the last bubble is on
                            // screen, we treat the user as "at
                            // bottom" — covers the "almost there"
                            // perception cleanly.
                            //
                            // The modifier is attached to every
                            // bubble (SwiftUI doesn't let us
                            // conditionally attach inside a
                            // ForEach), but the closure ignores
                            // non-last events so it's a no-op for
                            // older messages entering/leaving.
                            .onScrollVisibilityChange(threshold: 0.25) { isVisible in
                                guard index == lastIndex else {
                                    return
                                }
                                self.isScrolledAwayFromBottom = !isVisible
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                // Generous vertical breathing room so the first
                // bubble doesn't kiss the toolbar buttons and the
                // last one doesn't tuck under the input strip — both
                // were happening at the previous 8/12pt insets.
                .padding(.top, 24)
                .padding(.bottom, 28)
            }
            // Tap anywhere in the scroll area to drop the keyboard
            // (matches Niora's behavior — flipping `inputFocused` to
            // false relinquishes first-responder cleanly without the
            // resignFirstResponder bridge).
            .contentShape(Rectangle())
            .onTapGesture { self.inputFocused = false }
            // System interactive dismiss — drag down on messages and
            // the keyboard tracks finger position before falling away.
            .scrollDismissesKeyboard(.interactively)
            // Floating "scroll to latest" button overlaid at the
            // bottom-center of the message list. Shows only when the
            // last message is meaningfully off-screen, and tapping
            // it smoothly snaps the latest bubble into view.
            .overlay(alignment: .bottom) {
                self.scrollToBottomButton(proxy: proxy)
                    .animation(
                        .smooth(duration: 0.22),
                        value: self.isScrolledAwayFromBottom
                    )
            }
            .onChange(of: self.transcript.count) { _, _ in
                if let last = transcript.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            // When the keyboard opens, snap to the latest message so
            // it lands right above the keyboard's top edge instead of
            // hiding under it. (safeAreaInset already moves the input
            // bar; this keeps the scroll position aligned with it.)
            .onChange(of: self.inputFocused) { _, focused in
                guard focused, let last = transcript.last else {
                    return
                }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            // Middleware writes recalled memories to the inbox from a
            // background task; drain into the active assistant slot
            // here so the bubble renders a "Recalled N memories" pill.
            .onChange(of: self.inbox.pendingRecall) { _, texts in
                guard !texts.isEmpty else {
                    return
                }
                self.setRecalledOnLastAssistant(texts)
            }
            // The smooth-streamer drains pending tokens at a steady
            // cadence; mirror its `displayed` string into the active
            // assistant transcript item so the bubble re-renders
            // smoothly instead of in bursts as deltas land.
            //
            // Also pin the scroll position to the bottom of the active
            // bubble as it grows — without this the bottom edge of the
            // bubble slides under the input bar as more tokens arrive,
            // and the latest text disappears off-screen. Plain
            // `scrollTo` (no `withAnimation`) at the 25 ms drain
            // cadence reads as a smooth "follow," whereas animating
            // every tick stacks up overlapping animations and stutters.
            .onChange(of: self.streamer.displayed) { _, text in
                self.updateLastAssistant(text: text)
                if let last = transcript.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    /// Welcome surface shown when the active thread has no messages.
    /// Same view tree in both modes — properties (font size, padding,
    /// subtitle opacity + collapsed height) animate based on
    /// `inputFocused` so the elements morph in place instead of one
    /// view fading out while another fades in. The old if/else swap
    /// of distinct trees produced a jarring double-fade; a single
    /// tree with animated properties moves like one coherent piece.
    private var emptyState: some View {
        let compact = self.inputFocused
        return VStack(spacing: compact ? 6 : 18) {
            Image(systemName: "sparkles")
                .font(.system(size: compact ? 30 : 72, weight: .semibold))
                .foregroundStyle(self.sparklesGradient)
            Text("Hi, I'm Avyra")
                .font(.system(
                    size: compact ? 19 : 28,
                    weight: .bold,
                    design: .default
                ))
                .foregroundStyle(.primary)
            // Subtitle uses opacity + collapsed height so SwiftUI
            // interpolates rather than running a `.transition` (which
            // is what made the old swap feel like a glitch).
            Text("Ask me anything — ideas, plans, recipes, or just a fun fact.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .opacity(compact ? 0 : 1)
                .frame(height: compact ? 0 : nil, alignment: .top)
                .clipped()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, compact ? 16 : 60)
        .padding(.bottom, compact ? 8 : 40)
    }

    /// Niora-style input bar: a single glass capsule containing the
    /// attach button (when vision-capable), the text field, and the
    /// send button. Buttons are 44pt circles (Apple HIG minimum
    /// tap target); send is accent-tinted when there's text or an
    /// attached image.
    ///
    /// Focus state plumbing: bind `$inputFocused` to the field so
    /// the tap-anywhere-in-the-message-list gesture can dismiss the
    /// keyboard cleanly, and the toolbar adds a "Done" affordance
    /// while focused.
    private var inputBar: some View {
        VStack(spacing: 6) {
            if !self.pendingImages.isEmpty {
                self.pendingImagesStrip
            }
            HStack(alignment: .bottom, spacing: 8) {
                if self.activeProviderSupportsVision {
                    self.attachButton
                }
                TextField("Type Here..", text: self.$input, axis: .vertical)
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .lineLimit(1...6)
                    .disabled(self.isStreaming)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                    .focused(self.$inputFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await self.send() } }
                self.sendButton
            }
            .padding(8)
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: 32, style: .continuous)
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .onChange(of: self.pickedImages) { _, newValue in
            Task { await self.loadPickedImages(newValue) }
        }
    }

    private var attachButton: some View {
        // PhotosPicker enforces the per-turn cap via maxSelectionCount,
        // and we still keep `remainingAttachmentSlots` (computed below)
        // shrinking as the strip fills, so the user can't pick more
        // than they're allowed to send this turn.
        PhotosPicker(
            selection: self.$pickedImages,
            maxSelectionCount: self.remainingAttachmentSlots,
            matching: .images,
            photoLibrary: .shared()
        ) {
            Image(systemName: "paperclip")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(Color(.tertiarySystemFill))
                .clipShape(Circle())
        }
        .disabled(self.isStreaming || self.remainingAttachmentSlots == 0)
        .accessibilityLabel("Attach images")
    }

    private var sendButton: some View {
        Button {
            Task { await self.send() }
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(self.canSend ? Color.accentColor : .secondary)
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(
                        self.canSend
                            ? Color.accentColor.opacity(0.20)
                            : Color(.tertiarySystemFill)
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(self.canSend == false)
        .transition(.scale.combined(with: .opacity))
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: self.canSend)
        .accessibilityLabel("Send")
    }

    /// Horizontal strip of pending attachment thumbnails. Each
    /// thumbnail has its own corner-mounted remove button so users
    /// can drop individual images instead of clearing the whole batch.
    /// Pinned above the input capsule with a trailing count chip when
    /// the strip is full so the user knows why the picker is disabled.
    private var pendingImagesStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(self.pendingImages.enumerated()), id: \.offset) { index, data in
                    self.thumbnail(data: data, at: index)
                }
                if self.remainingAttachmentSlots == 0 {
                    Text("\(self.pendingImages.count)/\(Self.maxAttachments)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color(.tertiarySystemBackground)))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .frame(height: 76)
    }

    /// Welcome surface shown when the active thread has no messages.
    /// A large bare sparkles glyph tinted with the accent/purple
    /// gradient, then a personal greeting and an open invitation —
    /// no internal plumbing references.
    /// Floating "jump to latest message" affordance. Rendered as a
    /// 44pt glass circle anchored to the bottom-trailing corner of
    /// the message list. Visible only when the user has scrolled
    /// meaningfully above the bottom — once they hit the floor, the
    /// button fades + scales out so it doesn't compete with the
    /// input bar. Tap snaps to the last bubble with a soft animation.
    @ViewBuilder
    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        if self.isScrolledAwayFromBottom, !self.transcript.isEmpty {
            Button {
                withAnimation(.smooth(duration: 0.32)) {
                    if let last = transcript.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            } label: {
                Image(systemName: "arrow.down")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .glassEffect(.regular, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .accessibilityLabel("Scroll to latest message")
        }
    }

    private func thumbnail(data: Data, at index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            if let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.tertiarySystemBackground))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    )
            }
            Button {
                self.removeAttachment(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove attachment")
        }
    }

    private static func transcriptItem(from message: Message) -> TranscriptItem? {
        switch message.role {
        case .user:
            // Pull the inline image bytes out of the Message content
            // so reloaded history still shows what the user sent.
            // Anything other than `.image(.data(...))` is skipped —
            // URL/identifier sources would need async resolution we
            // don't do on the chat reload path.
            let images: [Data] = message.content.compactMap { part in
                guard case let .image(content) = part,
                      case let .data(bytes, _) = content.source else {
                    return nil
                }
                return bytes
            }
            return .user(message.textContent, images: images)
        case .assistant where !message.textContent.isEmpty:
            return .assistant(message.textContent)
        default:
            return nil
        }
    }

    private static func buildUserMessage(text: String, images: [Data]) -> Message {
        guard !images.isEmpty else {
            return Message.user(text)
        }
        let imageContents = images.map { data in
            ImageContent(source: .data(data, mimeType: "image/jpeg"))
        }
        return Message.user(text, images: imageContents)
    }

    /// Group-aware avatar gating — only the FIRST bubble in a run of
    /// same-role messages shows the avatar. Subsequent bubbles
    /// render a transparent spacer so text alignment is consistent.
    private func isFirstInGroup(at index: Int) -> Bool {
        guard index > 0 else {
            return true
        }
        return self.transcript[index].role != self.transcript[index - 1].role
    }

    /// Resolve `PhotosPickerItem`s into JPEG bytes, downsampled to
    /// `ImageDownsampler.maxPixelSize` *before* they enter any of the
    /// chat's long-lived storage (the strip, the transcript item, the
    /// agent message persisted by `HistoryMiddleware`).
    ///
    /// Without the downsample step a single 6-image batch from a 12 MP
    /// camera roll can push the process past iOS's memory limit and
    /// trigger jetsam — even with the `increased-memory-limit`
    /// entitlement. The downsample happens off the main thread via
    /// `Task.detached` so a heavy batch doesn't jank the input bar.
    @MainActor
    private func loadPickedImages(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else {
            return
        }
        var loaded: [Data] = []
        for item in items {
            guard let raw = try? await item.loadTransferable(type: Data.self) else {
                continue
            }
            let shrunk = await Task.detached(priority: .userInitiated) {
                ImageDownsampler.downsample(raw)
            }.value
            loaded.append(shrunk)
        }
        self.pendingImages.append(contentsOf: loaded)
        if self.pendingImages.count > Self.maxAttachments {
            self.pendingImages = Array(self.pendingImages.prefix(Self.maxAttachments))
        }
        // Clear the picker selection so the next attach tap starts
        // fresh and `onChange` re-fires for newly-picked items.
        self.pickedImages = []
    }

    @MainActor
    private func removeAttachment(at index: Int) {
        guard self.pendingImages.indices.contains(index) else {
            return
        }
        self.pendingImages.remove(at: index)
    }

    @MainActor
    private func send() async {
        let trimmed = self.input.trimmingCharacters(in: .whitespaces)
        let attached = self.pendingImages
        guard !trimmed.isEmpty || !attached.isEmpty else {
            return
        }

        // Empty text + image-only turn still needs *something* in the
        // user bubble's caption row; leave it blank and the bubble's
        // image-only path renders just the thumbnails.
        self.transcript.append(.user(trimmed, images: attached))
        self.input = ""
        self.pendingImages = []
        self.pickedImages = []
        self.isStreaming = true
        defer { isStreaming = false }
        self.inbox.reset()
        self.transcript.append(.assistant("", expectsThinking: self.activeModelIsReasoning))
        let userMessage = Self.buildUserMessage(text: trimmed, images: attached)
        await self.runAgent(userMessage: userMessage)
    }

    @MainActor
    private func runAgent(userMessage: Message) async {
        #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                await self.streamWithAgent(userMessage: userMessage)
                return
            }
        #endif
        self.updateLastAssistant(
            text: "FoundationModels requires iOS 26 or macOS 26."
        )
    }

    /// Append a tool-call name to the last assistant turn's metadata.
    /// The bubble renders these as pills above the message body so
    /// the streamed text stays clean.
    @MainActor
    private func appendToolCallToLastAssistant(name: String) {
        guard let lastIndex = transcript.indices.last,
              transcript[lastIndex].role == .assistant else {
            return
        }
        self.transcript[lastIndex].toolCalls.append(name)
    }

    /// Stamp the recalled-memory texts onto the last assistant turn.
    /// Called from the `RAGMiddleware.onRecall` callback which fires
    /// after the user message but before the model produces tokens —
    /// the assistant slot already exists by then (appended in `send`).
    @MainActor
    private func setRecalledOnLastAssistant(_ texts: [String]) {
        guard let lastIndex = transcript.indices.last,
              transcript[lastIndex].role == .assistant else {
            return
        }
        self.transcript[lastIndex].recalledMemories = texts
    }

    /// Attach an `AssistantError` to the last assistant turn so the
    /// bubble swaps to `ErrorCard` rendering. Any partial text the
    /// stream produced before failing is preserved — the card sits
    /// below it.
    @MainActor
    private func setErrorOnLastAssistant(_ error: AssistantError) {
        guard let lastIndex = transcript.indices.last,
              transcript[lastIndex].role == .assistant else {
            return
        }
        self.transcript[lastIndex].error = error
    }

    /// Mint a fresh thread id and drop the visible transcript. The
    /// prior thread's messages stay in GRDB — they show up in
    /// Settings → Previous chats. The freshly-minted id only becomes
    /// a real "thread" in storage once the user actually sends a
    /// message (HistoryMiddleware writes on first turn).
    @MainActor
    private func startNewChat() {
        self.transcript = []
        self.input = ""
        self.pendingImages = []
        self.pickedImages = []
        self.inbox.reset()
        self.currentThreadId = UUID().uuidString
    }

    /// Switch to a previously-saved thread. Loads its persisted
    /// messages into the visible transcript and swaps the
    /// `currentThreadId` so the next agent build resumes that
    /// conversation under HistoryMiddleware.
    ///
    /// The final transcript swap runs inside `withAnimation` so the
    /// new bubbles fade in rather than snapping in — matters because
    /// this is called from the Settings → Previous chats sheet
    /// dismissal and the user sees the transition through the sheet's
    /// fade-away.
    @MainActor
    private func loadThread(_ threadId: String) async {
        self.input = ""
        self.pendingImages = []
        self.pickedImages = []
        self.inbox.reset()
        self.currentThreadId = threadId
        do {
            let messages = try await self.storage.chatHistory.messages(threadId: threadId)
            let items = messages.compactMap(Self.transcriptItem(from:))
            withAnimation(.smooth(duration: 0.35)) {
                self.transcript = items
            }
        } catch {
            withAnimation(.smooth) {
                self.transcript = [.assistant("Could not load chat: \(error)")]
            }
        }
    }

    @MainActor
    private func updateLastAssistant(text: String) {
        guard let lastIndex = transcript.indices.last,
              transcript[lastIndex].role == .assistant else {
            return
        }
        self.transcript[lastIndex].content = text
    }
}

// MARK: - TranscriptItem

/// One row in the chat transcript. User rows carry just text; assistant
/// rows also carry per-turn metadata that the bubble renders as
/// accessory pills (recalled memories from RAG, tool calls emitted
/// during the turn) so the message body stays clean instead of
/// inline-tagged with `[recalled: …]` / `[calling X]` noise.
struct TranscriptItem: Identifiable {
    enum Role { case user, assistant }

    let id = UUID()
    var role: Role
    /// Raw text the model emitted. For assistant rows this still
    /// includes `<think>…</think>` blocks if any — stripping happens
    /// in `MessageContentParser` at render time so partial streams
    /// don't corrupt content.
    var content: String
    /// Names of tools the agent fired during this turn. Always empty
    /// for user rows. Rendered as small pills above the bubble.
    var toolCalls: [String] = []
    /// Memory items `RAGMiddleware.onRecall` surfaced for this turn.
    /// Always empty for user rows.
    var recalledMemories: [String] = []
    /// JPEG byte buffers for images the user attached to this turn.
    /// Always empty for assistant rows. Rendered as thumbnails above
    /// the user bubble so the sender can see exactly what they sent.
    var attachedImages: [Data] = []

    /// Set when the provider stream failed for this turn. When
    /// present, the bubble swaps its normal text body for an
    /// `ErrorCard` showing the friendly summary; the raw technical
    /// dump is only revealed in developer mode.
    var error: AssistantError?

    /// `true` when this turn's model is a reasoning model that
    /// streams its reasoning before producing a final reply (Qwen
    /// 3.x, DeepSeek R1, …). Drives implicit-thinking parsing in
    /// `MessageContentParser` so reasoning text never leaks into
    /// the visible bubble while the model is still thinking.
    var expectsThinking: Bool = false

    static func user(_ text: String, images: [Data] = []) -> TranscriptItem {
        .init(role: .user, content: text, attachedImages: images)
    }

    static func assistant(_ text: String, expectsThinking: Bool = false) -> TranscriptItem {
        .init(role: .assistant, content: text, expectsThinking: expectsThinking)
    }
}

// TranscriptItemView removed — replaced by `MessageBubble` which renders
// the assistant avatar + uses the Niora-style bubble layout.

// MARK: - FirstEventSentinel

/// Tiny actor the timeout watchdog reads to decide whether to fire.
/// Set to `true` the moment the SDK yields its first event of the
/// turn (text delta, tool call, anything). If still `false` when the
/// watchdog's sleep returns, no events have flowed and we should
/// surface a "model taking too long" error. If `true`, the model is
/// actively producing — let it run as long as it needs to, even if
/// that's several minutes (Qwen 3.5 reasoning, slow MLX loads, etc.).
private actor FirstEventSentinel {
    var wasSeen = false

    func markSeen() {
        self.wasSeen = true
    }
}
