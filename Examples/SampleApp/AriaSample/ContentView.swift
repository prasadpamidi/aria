import Aria
import AriaMLX
import AriaApple
import PhotosUI
import SwiftUI

#if canImport(FoundationModels)
    import FoundationModels
#endif

// MARK: - ContentView

struct ContentView: View {
    // MARK: Lifecycle

    init(storage: GRDBStorage) {
        self.storage = storage
    }

    // MARK: Internal

    var body: some View {
        VStack(spacing: 0) {
            self.header
            self.messageList
            self.inputBar
        }
        .background(Color(.systemBackground))
        .task {
            await self.loadHistory()
        }
        .sheet(isPresented: self.$memoriesSheetShown) {
            MemoriesSheet(storage: self.storage, namespace: Self.memoryNamespace)
        }
        .sheet(isPresented: self.$mlxModelsSheetShown) {
            #if canImport(AriaMLX)
                NavigationStack {
                    MLXModelsView(manager: self.appState.modelManager)
                        .navigationTitle("MLX Models")
                        .navigationBarTitleDisplayMode(.inline)
                }
            #endif
        }
        .sheet(item: self.$shareItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    // MARK: Private

    private static let threadId = "default"
    private static let memoryNamespace = ["sample", "default"]

    @State private var input: String = ""
    @State private var transcript: [TranscriptItem] = []
    @State private var isStreaming: Bool = false
    /// Per-turn recall surface. RAGMiddleware writes here via an
    /// `onRecall` callback so the UI can render which memories were
    /// injected before the model's reply.
    @State private var memoryProbe = MemoryProbe()
    @State private var memoriesSheetShown = false
    @State private var mlxModelsSheetShown = false
    /// Single recorder threaded into both the chat agent and the
    /// state-graph demo so a single "Share session" tap exports a
    /// bundle covering everything that ran in this session.
    @State private var sessionRecorder = SessionRecorder()
    @State private var shareItem: SessionShareItem?
    @State private var appState = AppState()
    @State private var pickedImage: PhotosPickerItem?
    /// JPEG data for the image the user attached to the next message.
    /// Cleared once the message is sent.
    @State private var pendingImageData: Data?

    private let storage: GRDBStorage

    // MARK: - Subviews

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Aria Sample").font(.headline)
                Text(self.providerLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            self.actionsMenu
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
    }

    /// Active-provider line shown under the title. Defaults to the
    /// FoundationModels label; switches to the MLX model display
    /// name when the user has selected one in the Models sheet.
    private var providerLabel: String {
        #if canImport(AriaMLX)
            if let capabilities = self.appState.modelManager.activeCapabilities {
                return capabilities.displayName
            }
        #endif
        return "Aria \(AriaInfo.version)  ·  FoundationModels"
    }

    private var actionsMenu: some View {
        Menu {
            Button("Memories…") { self.memoriesSheetShown = true }
            #if canImport(AriaMLX)
                Button("MLX models…") { self.mlxModelsSheetShown = true }
            #endif
            Button("Share session…") { Task { await self.exportSession() } }
            Button("Clear chat", role: .destructive) {
                Task { await self.clearHistory() }
            }
            #if canImport(FoundationModels)
                if #available(iOS 26.0, macOS 26.0, *) {
                    Section("Demos") {
                        Button("Suggest activity") { Task { await self.runSuggest() } }
                        Button("Run graph") { Task { await self.runHaikuChain() } }
                        Button("Resume graph") { Task { await self.resumeHaikuChain() } }
                    }
                }
            #endif
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
        }
        .disabled(self.isStreaming)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if self.transcript.isEmpty {
                        self.emptyState
                    } else {
                        ForEach(self.transcript) { item in
                            TranscriptItemView(item: item)
                                .id(item.id)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: self.transcript.count) { _, _ in
                if let last = transcript.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Aria package wired up.")
                .font(.headline)
            Text("Agent implementation is pending.\nSend a message to see the placeholder echo.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if self.pendingImageData != nil {
                self.pendingImagePreview
            }
            HStack(spacing: 8) {
                if self.activeProviderSupportsVision {
                    PhotosPicker(
                        selection: self.$pickedImage,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Image(systemName: "paperclip")
                            .font(.title3)
                    }
                    .disabled(self.isStreaming)
                }
                TextField("Ask anything…", text: self.$input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .disabled(self.isStreaming)

                Button {
                    Task { await self.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(self.canSend == false)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .onChange(of: self.pickedImage) { _, newValue in
            Task { await self.loadPickedImage(newValue) }
        }
    }

    @ViewBuilder
    private var pendingImagePreview: some View {
        if let data = pendingImageData, let uiImage = UIImage(data: data) {
            HStack {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("Image attached")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    self.pendingImageData = nil
                    self.pickedImage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var canSend: Bool {
        if self.isStreaming { return false }
        let hasText = !self.input.trimmingCharacters(in: .whitespaces).isEmpty
        return hasText || self.pendingImageData != nil
    }

    /// `true` when the currently-active provider can actually consume
    /// images. We hide the photo-picker button otherwise so users
    /// don't attach an image that would be silently dropped.
    private var activeProviderSupportsVision: Bool {
        #if canImport(AriaMLX)
            if let entry = self.appState.modelManager.activeCapabilities {
                return entry.supportsVision
            }
        #endif
        return false
    }

    @MainActor
    private func loadPickedImage(_ item: PhotosPickerItem?) async {
        guard let item else {
            self.pendingImageData = nil
            return
        }
        do {
            self.pendingImageData = try await item.loadTransferable(type: Data.self)
        } catch {
            self.pendingImageData = nil
        }
    }

    private static func transcriptItem(from message: Message) -> TranscriptItem? {
        switch message.role {
        case .user: .user(message.textContent)
        case .assistant where !message.textContent.isEmpty: .assistant(message.textContent)
        default: nil
        }
    }

    @MainActor
    private func send() async {
        let trimmed = self.input.trimmingCharacters(in: .whitespaces)
        let attached = self.pendingImageData
        guard !trimmed.isEmpty || attached != nil else {
            return
        }

        let displayText = trimmed.isEmpty ? "[image]" : trimmed
        self.transcript.append(.user(displayText))
        self.input = ""
        self.pendingImageData = nil
        self.pickedImage = nil
        self.isStreaming = true
        defer { isStreaming = false }

        self.transcript.append(.assistant(""))
        let userMessage = Self.buildUserMessage(text: trimmed, image: attached)
        await self.runAgent(userMessage: userMessage)
    }

    private static func buildUserMessage(text: String, image: Data?) -> Message {
        if let image {
            let imageContent = ImageContent(source: .data(image, mimeType: "image/jpeg"))
            return Message.user(text, images: [imageContent])
        }
        return Message.user(text)
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

    #if canImport(FoundationModels)
        @available(iOS 26.0, macOS 26.0, *)
        @MainActor
        private func streamWithAgent(userMessage: Message) async {
            self.memoryProbe.lastRecalled = []
            let agent = self.makeAgent()
            var assistantText = ""
            do {
                for try await event in agent.stream(.message(userMessage)) {
                    switch event {
                    case let .textDelta(chunk):
                        assistantText += chunk
                        self.updateLastAssistant(text: self.composeAssistant(assistantText))
                    case let .toolCallRequested(call):
                        let badge = "[calling \(call.name)]"
                        assistantText = self.withInlineBadge(assistantText, badge: badge)
                        self.updateLastAssistant(text: self.composeAssistant(assistantText))
                    case .finish:
                        return
                    case let .error(err):
                        self.updateLastAssistant(text: "Error: \(err)")
                        return
                    default:
                        break
                    }
                }
            } catch {
                self.updateLastAssistant(text: "Error: \(error)")
            }
        }

        /// Prepend a "recalled:" badge to the assistant text when
        /// RAGMiddleware injected memories on this turn. Keeps the
        /// retrieval result visible inline so the user can verify
        /// embeddings are actually doing something.
        @MainActor
        private func composeAssistant(_ text: String) -> String {
            guard !self.memoryProbe.lastRecalled.isEmpty else {
                return text
            }
            let badge = "[recalled: \(self.memoryProbe.lastRecalled.joined(separator: " · "))]"
            return text.isEmpty ? badge : badge + "\n\n" + text
        }

        @available(iOS 26.0, macOS 26.0, *)
        private func makeAgent() -> Agent {
            let memory = self.makeMemoryStore()
            let middlewares = self.makeMiddleware(memory: memory)
            // Register each tool once and harvest both the AnyTool (for
            // the agent's portable list) and the typed FM factory (for
            // the provider's tool router) from the same kit. This keeps
            // the two lists in sync — the bridge is the only path FM's
            // iOS 26 router actually fires.
            var kits: [FoundationModelsToolKit] = [
                registerFoundationModelsTool(CurrentTimeTool()),
            ]
            if let memory {
                kits.append(registerFoundationModelsTool(
                    RememberTool(memoryStore: memory, namespace: Self.memoryNamespace)
                ))
            }
            let provider: any LLMProvider = self.makeProvider(kits: kits)
            // Vision-only MLX models (e.g. Gemma 4 e2b/e4b VLM) advertise
            // `supportsToolUse: false`. Passing tools to them trips
            // `Agent.validateConfig`, so gate the agent's tool list on
            // the active provider's capability.
            let toolsForAgent = provider.capabilities.supportsToolUse
                ? kits.map(\.anyTool)
                : []
            return Agent(config: AgentConfig(
                provider: provider,
                tools: toolsForAgent,
                systemPrompt: Self.systemPrompt(memoryEnabled: memory != nil),
                threadId: Self.threadId,
                middleware: middlewares
            ))
        }

        /// Pick the active LLM provider based on the user's
        /// per-conversation choice. When an MLX model is selected
        /// (and AriaMLX is available) we route through `MLXProvider`
        /// using the long-lived `MLXModelStore` from `AppState`.
        /// Otherwise we fall back to FoundationModels with the
        /// typed-tool kits the chat agent has always used.
        @available(iOS 26.0, macOS 26.0, *)
        private func makeProvider(
            kits: [FoundationModelsToolKit]
        ) -> any LLMProvider {
            #if canImport(AriaMLX)
                if let mlx = self.appState.modelManager.makeProvider(
                    defaultInstructions: Self.systemPrompt(memoryEnabled: false)
                ) {
                    return mlx
                }
            #endif
            return FoundationModelsProvider(typedTools: kits.map(\.factory))
        }

        /// Returns a configured `MemoryStore`, or `nil` when the OS does
        /// not ship an `NLEmbedding` for the chosen language. The sample
        /// degrades gracefully — agent + history still work.
        ///
        /// Vectors persist in the same `GRDBStorage` SQLite file as
        /// chat history, so remembered facts survive process restarts.
        private func makeMemoryStore() -> (any MemoryStore)? {
            guard let embedder = NLEmbeddingEmbedder() else {
                return nil
            }
            let store = self.storage.vectorStore(dimensions: embedder.dimensions)
            return DefaultMemoryStore(embedder: embedder, store: store)
        }

        /// Production-grade middleware chain. Order matters:
        ///   1. `HistoryMiddleware` — load persisted transcript from GRDB
        ///      on `beforeRun`, then write each new message after every
        ///      step.
        ///   2. `HistorySummarizationMiddleware` — when the thread grows
        ///      past `triggerAfterTurns`, compress the older portion
        ///      into a single `.system` summary message. Sized small
        ///      here (8 / 4) so the demo trips it after a handful of
        ///      turns and you can see the behavior; production typical
        ///      defaults are more like 24 / 6.
        ///   3. `HistoryWindowMiddleware` — hard cap (turns + tokens)
        ///      that ensures the provider sees a bounded slice even if
        ///      summarization isn't enough.
        ///   4. `RAGMiddleware` — recall top-K user memories for the
        ///      latest message and prepend them as a system block.
        ///   5. `FactExtractionMiddleware` — after each turn, mine
        ///      durable facts from the latest user message and write
        ///      them into the same `MemoryStore` RAG reads from.
        ///   6. `RecordingMiddleware` — last, so it observes the
        ///      final agent stream events.
        ///
        /// The summarizer and extractor closures call the on-device
        /// FoundationModels model directly via a fresh, history-less
        /// agent — keeps the auxiliary work on-device and avoids
        /// recursing through the main agent's middleware stack.
        private func makeMiddleware(memory: (any MemoryStore)?) -> [any AgentMiddleware] {
            var middlewares: [any AgentMiddleware] = [
                HistoryMiddleware(history: self.storage.chatHistory),
            ]
            #if canImport(FoundationModels)
                if #available(iOS 26.0, macOS 26.0, *) {
                    middlewares.append(
                        HistorySummarizationMiddleware(
                            triggerAfterTurns: 8,
                            keepRecentTurns: 4,
                            summarizer: Self.makeAuxiliarySummarizer()
                        )
                    )
                }
            #endif
            middlewares.append(
                HistoryWindowMiddleware(maxTurns: 16, maxTokens: 4000)
            )
            if let memory {
                let probe = self.memoryProbe
                middlewares.append(
                    RAGMiddleware(
                        memoryStore: memory,
                        namespace: Self.memoryNamespace,
                        topK: 4,
                        onRecall: { matches in
                            let texts = matches.map(\.item.content)
                            Task { @MainActor in probe.lastRecalled = texts }
                        }
                    )
                )
                #if canImport(FoundationModels)
                    if #available(iOS 26.0, macOS 26.0, *) {
                        middlewares.append(
                            FactExtractionMiddleware(
                                memory: memory,
                                namespace: Self.memoryNamespace,
                                extractor: Self.makeAuxiliaryFactExtractor()
                            )
                        )
                    }
                #endif
            }
            let recording = RecordingMiddleware(recorder: self.sessionRecorder)
            recording.bind(
                providerSystem: "apple.foundationmodels.default",
                providerModel: "apple.foundationmodels.default",
                systemPrompt: Self.systemPrompt(memoryEnabled: memory != nil)
            )
            middlewares.append(recording)
            return middlewares
        }

        /// Build the summarizer closure `HistorySummarizationMiddleware`
        /// hands the older portion of a thread to. Runs a fresh,
        /// history-less FoundationModels agent so the auxiliary call
        /// doesn't recurse back through the main middleware chain (which
        /// would re-trigger summarization on the summarizer's input).
        @available(iOS 26.0, macOS 26.0, *)
        private static func makeAuxiliarySummarizer() -> @Sendable ([Message]) async throws -> String {
            { messages in
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
        }

        /// Build the extractor closure `FactExtractionMiddleware` calls
        /// with the latest user message. Returns the list of fact
        /// strings the middleware stores; empty list means "nothing
        /// durable worth saving."
        @available(iOS 26.0, macOS 26.0, *)
        private static func makeAuxiliaryFactExtractor() -> @Sendable (Message) async throws -> [String] {
            { message in
                let prompt = """
                Extract durable facts about the user from the message below. \
                A "durable fact" is something likely to remain true across \
                many sessions: preferences, goals, constraints, schedule, \
                equipment. NOT one-off questions, current state, or emotions.

                Return ONLY a JSON array of short fact strings. \
                Examples: ["user prefers metric units", "user is vegetarian"]. \
                Empty array if nothing durable. NO prose, NO markdown — JUST the array.

                Message: \(message.textContent)
                """
                let raw = try await Self.runAuxiliaryCompletion(
                    systemPrompt: "You are a precise fact extractor. Output only a JSON array of strings.",
                    userText: prompt
                )
                let cleaned = raw
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "```json", with: "")
                    .replacingOccurrences(of: "```", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let data = cleaned.data(using: .utf8),
                      let array = try? JSONSerialization.jsonObject(with: data) as? [String]
                else {
                    return []
                }
                return array.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            }
        }

        /// One-shot auxiliary completion via a fresh FoundationModels
        /// agent — no middleware, no history. Used by both the
        /// summarizer and the extractor.
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

        private static func systemPrompt(memoryEnabled: Bool) -> String {
            // Keep this prompt about *behavior*, not tool routing. Naming
            // tools in the prompt nudges the model to mimic that text
            // pattern in its replies; the tool descriptions registered
            // with the session already tell the model what each tool
            // does and when to use it.
            var lines: [String] = [
                "You are a concise, helpful assistant.",
                "Always use the tools you have access to when they are relevant — "
                    + "never describe a tool call in your reply text.",
            ]
            if memoryEnabled {
                lines.append(
                    "Save anything the user wants you to remember about themselves "
                        + "for future conversations."
                )
            }
            return lines.joined(separator: " ")
        }

        private func withInlineBadge(_ text: String, badge: String) -> String {
            text.isEmpty ? badge + "\n" : text + "\n" + badge + "\n"
        }
    #endif

    @MainActor
    private func loadHistory() async {
        guard self.transcript.isEmpty else {
            return
        }
        do {
            let messages = try await self.storage.chatHistory.messages(
                threadId: Self.threadId
            )
            self.transcript = messages.compactMap(Self.transcriptItem(from:))
        } catch {
            // Surface load failures inline rather than crashing the app.
            self.transcript = [.assistant("Could not load history: \(error)")]
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

// MARK: - Structured response demo

#if canImport(FoundationModels)
    extension ContentView {
        /// Stream an `ActivitySuggestion` from `agent.respond(_:as:)`,
        /// rendering each partial snapshot in place so the user sees the
        /// model fill in fields incrementally.
        @available(iOS 26.0, macOS 26.0, *)
        @MainActor
        func runSuggest() async {
            self.isStreaming = true
            defer { isStreaming = false }
            self.transcript.append(.user("Suggest a fun activity for me today."))
            self.transcript.append(.assistant(""))
            // Use a tool-free agent for the structured demo. The chat
            // agent's tools (current_time, remember_fact) and its
            // "always use tools" system prompt aren't relevant here,
            // and registering them alongside a structured response can
            // make the model spin on tool routing instead of producing
            // snapshots.
            let suggestAgent = Agent(config: AgentConfig(
                provider: FoundationModelsProvider(),
                tools: [],
                systemPrompt: "Suggest one specific fun activity. Reply only via the structured response.",
                threadId: "suggest-demo"
            ))
            do {
                let stream = suggestAgent.respond(
                    .message(.user("Suggest a fun activity I could do today.")),
                    as: ActivitySuggestion.self
                )
                for try await event in stream {
                    switch event {
                    case let .partial(snapshot):
                        self.updateLastAssistant(text: Self.render(snapshot))
                    case .toolCallExecuted:
                        break
                    case let .finish(suggestion):
                        self.updateLastAssistant(text: Self.render(suggestion))
                        return
                    }
                }
            } catch {
                self.updateLastAssistant(text: "Error: \(error)")
            }
        }

        @available(iOS 26.0, macOS 26.0, *)
        private static func render(
            _ partial: ActivitySuggestion.PartiallyGenerated
        ) -> String {
            let title = partial.title ?? "…"
            let summary = partial.summary ?? "…"
            let steps = partial.steps?.enumerated()
                .map { "  \($0.offset + 1). \($0.element)" }
                .joined(separator: "\n") ?? "  …"
            return "🎯 \(title)\n\n\(summary)\n\nSteps:\n\(steps)"
        }

        @available(iOS 26.0, macOS 26.0, *)
        private static func render(_ suggestion: ActivitySuggestion) -> String {
            let steps = suggestion.steps.enumerated()
                .map { "  \($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            return "🎯 \(suggestion.title)\n\n\(suggestion.summary)\n\nSteps:\n\(steps)"
        }
    }
#endif

// MARK: - StateGraph demo

#if canImport(FoundationModels)
    extension ContentView {
        /// Build and run the haiku-chain `StateGraph`, updating the
        /// inline assistant bubble each time a node finishes so the
        /// user can watch the state fill in step by step.
        @available(iOS 26.0, macOS 26.0, *)
        @MainActor
        func runHaikuChain() async {
            let recorder = self.sessionRecorder
            await self.driveHaikuChain(
                userLabel: "[Graph] haiku chain",
                stream: { compiled, checkpointConfig in
                    compiled.stream(
                        initial: HaikuChainState(),
                        options: .init(checkpoint: checkpointConfig, recorder: recorder)
                    )
                }
            )
        }

        /// Resume the haiku chain from the latest checkpoint stored in
        /// the GRDB checkpointer. Useful for verifying that the V2
        /// resume API actually picks up where execution left off — kill
        /// the app mid-Graph and tap Resume on relaunch.
        @available(iOS 26.0, macOS 26.0, *)
        @MainActor
        func resumeHaikuChain() async {
            await self.driveHaikuChain(
                userLabel: "[Graph] resume",
                stream: { compiled, _ in
                    compiled.resume(
                        threadId: HaikuChain.threadId,
                        checkpointer: self.storage.checkpointer
                    )
                }
            )
        }

        /// Shared driver: build the agent + compiled graph, run the
        /// supplied `stream` closure, and re-render the bubble on each
        /// event. Centralizes the checkpoint config so both fresh runs
        /// and resumes write back to the same thread.
        @available(iOS 26.0, macOS 26.0, *)
        @MainActor
        private func driveHaikuChain(
            userLabel: String,
            stream: (CompiledStateGraph<HaikuChainState>, CompiledStateGraph<HaikuChainState>.CheckpointConfig)
                -> AsyncThrowingStream<StateGraphEvent<HaikuChainState>, any Error>
        ) async {
            self.isStreaming = true
            defer { isStreaming = false }
            self.transcript.append(.user(userLabel))
            self.transcript.append(.assistant("[Graph] starting…"))
            do {
                let compiled = try HaikuChain.build(agent: HaikuChain.makeAgent())
                let checkpointConfig = CompiledStateGraph<HaikuChainState>.CheckpointConfig(
                    checkpointer: self.storage.checkpointer,
                    threadId: HaikuChain.threadId
                )
                for try await event in stream(compiled, checkpointConfig) {
                    switch event {
                    case let .nodeStart(name, state):
                        self.updateLastAssistant(text: Self.renderHaiku(state: state, running: name))
                    case let .nodeEnd(_, state):
                        self.updateLastAssistant(text: Self.renderHaiku(state: state, running: nil))
                    case let .finish(state):
                        self.updateLastAssistant(text: Self.renderHaiku(state: state, running: nil))
                    }
                }
            } catch {
                self.updateLastAssistant(text: "[Graph error] \(error)")
            }
        }

        @available(iOS 26.0, macOS 26.0, *)
        private static func renderHaiku(
            state: HaikuChainState,
            running: String?
        ) -> String {
            var lines = ["[Graph]"]
            if let topic = state.topic {
                lines.append("→ brainstorm: \(topic)")
            }
            if let haiku = state.haiku {
                lines.append("→ haiku:\n\(haiku)")
            }
            if let critique = state.critique {
                lines.append("→ critique: \(critique)")
            }
            if let running {
                lines.append("running \(running)…")
            }
            return lines.joined(separator: "\n")
        }
    }
#endif

// MARK: - History controls

extension ContentView {
    /// Wipe the chat thread and the on-screen transcript. Keeps the
    /// vector store intact (long-lived facts shouldn't disappear with a
    /// chat reset). Used to clear bad model patterns out of the history
    /// that the FoundationModels transcript replays back to the model.
    @MainActor
    func clearHistory() async {
        do {
            try await self.storage.chatHistory.clear(threadId: Self.threadId)
            self.transcript = []
        } catch {
            self.transcript = [.assistant("Could not clear history: \(error)")]
        }
    }

    /// Build the current `SessionBundle` from the shared
    /// `SessionRecorder`, write it as pretty JSON to a temp file, and
    /// hand the URL to a share sheet. Lets the user export an entire
    /// run — chat agent steps + state-graph node transitions — in
    /// one tap.
    @MainActor
    func exportSession() async {
        do {
            let bundle = await self.sessionRecorder.bundle()
            let url = try Self.writeBundleToTempFile(bundle)
            self.shareItem = SessionShareItem(url: url)
        } catch {
            self.transcript = [.assistant("Could not export session: \(error)")]
        }
    }

    private static func writeBundleToTempFile(_ bundle: SessionBundle) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bundle)
        let filename = "aria-session-\(bundle.id).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }
}

// MARK: - TranscriptItem

struct TranscriptItem: Identifiable {
    enum Role { case user, assistant }

    let id = UUID()
    var role: Role
    var content: String

    static func user(_ text: String) -> TranscriptItem {
        .init(role: .user, content: text)
    }

    static func assistant(_ text: String) -> TranscriptItem {
        .init(role: .assistant, content: text)
    }
}

// MARK: - TranscriptItemView

struct TranscriptItemView: View {
    // MARK: Internal

    let item: TranscriptItem

    var body: some View {
        HStack(alignment: .top) {
            if self.item.role == .assistant {
                self.bubble
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                self.bubble
            }
        }
    }

    // MARK: Private

    private var bubble: some View {
        Text(self.item.content)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        self.item.role == .user
                            ? Color.accentColor.opacity(0.15)
                            : Color(.tertiarySystemBackground)
                    )
            )
    }
}

#Preview {
    if let storage = try? GRDBStorage() {
        ContentView(storage: storage)
    } else {
        Text("Preview unavailable: in-memory GRDBStorage failed to initialize")
            .padding()
    }
}
