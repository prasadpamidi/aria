import Aria
import AriaApple
import PhotosUI
import SwiftUI

#if canImport(AriaMLX)
    import AriaMLX
#endif
#if canImport(FoundationModels)
    import FoundationModels
#endif

// MARK: - ChatScreen

/// The chat surface — message list, input bar, optional image
/// attachment, recall badge. Extracted from the prior monolithic
/// `ContentView` so it's just the chat: demos / memories / settings
/// live in their own tabs.
///
/// Settings (memory on/off, summarization config, window caps, RAG
/// top-K) come from `@Environment(\.ariaSettings)` and re-read on
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
        VStack(spacing: 0) {
            ChatHeader(
                providerLabel: self.providerLabel,
                memoryEnabled: self.settings.memoryEnabled,
                onPickModel: { self.modelPickerShown = true },
                onClearChat: { Task { await self.clearHistory() } },
                isStreaming: self.isStreaming,
                canClearChat: !self.transcript.isEmpty
            )
            self.messageList
            self.inputBar
        }
        .background(Color(.systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: self.$modelPickerShown) {
            ModelPickerSheet(appState: self.appState) {
                self.modelPickerShown = false
            }
            .presentationDetents([.medium, .large])
        }
        .task { await self.loadHistory() }
    }

    // MARK: Private

    @State private var input: String = ""
    @State private var transcript: [TranscriptItem] = []
    @State private var isStreaming: Bool = false
    @State private var memoryProbe = MemoryProbe()
    @State private var pickedImage: PhotosPickerItem?
    @State private var pendingImageData: Data?
    @State private var modelPickerShown = false

    @Environment(\.ariaSettings) private var settings

    private let storage: GRDBStorage
    private let appState: AppState
    private let sessionRecorder: SessionRecorder

    // MARK: - Subviews

    private var providerLabel: String {
        #if canImport(AriaMLX)
            if let capabilities = self.appState.modelManager.activeCapabilities {
                return capabilities.displayName
            }
        #endif
        return "Aria \(AriaInfo.version) · FoundationModels"
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if self.transcript.isEmpty {
                        self.emptyState
                    } else {
                        ForEach(Array(self.transcript.enumerated()), id: \.element.id) { index, item in
                            MessageBubble(
                                item: item,
                                isFirstInGroup: self.isFirstInGroup(at: index)
                            )
                            .id(item.id)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .onChange(of: self.transcript.count) { _, _ in
                if let last = transcript.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    /// Group-aware avatar gating — only the FIRST bubble in a run of
    /// same-role messages shows the avatar. Subsequent bubbles
    /// render a transparent spacer so text alignment is consistent.
    private func isFirstInGroup(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return self.transcript[index].role != self.transcript[index - 1].role
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Say hi to Aria")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Try \"remember I prefer metric units\" — switch to the Memories tab to see what stuck.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if self.pendingImageData != nil {
                self.pendingImagePreview
            }
            HStack(spacing: 10) {
                if self.activeProviderSupportsVision {
                    PhotosPicker(
                        selection: self.$pickedImage,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Image(systemName: "paperclip")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(self.isStreaming)
                }
                TextField("Message", text: self.$input, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...4)
                    .disabled(self.isStreaming)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Color(.secondarySystemBackground))
                    )
                Button {
                    Task { await self.send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle().fill(
                                self.canSend ? Color.accentColor : Color(.tertiarySystemFill)
                            )
                        )
                }
                .disabled(self.canSend == false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(.bar)
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
        self.pendingImageData = try? await item.loadTransferable(type: Data.self)
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
        guard !trimmed.isEmpty || attached != nil else { return }

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

        @MainActor
        private func composeAssistant(_ text: String) -> String {
            guard !self.memoryProbe.lastRecalled.isEmpty else { return text }
            let badge = "[recalled: \(self.memoryProbe.lastRecalled.joined(separator: " · "))]"
            return text.isEmpty ? badge : badge + "\n\n" + text
        }

        @available(iOS 26.0, macOS 26.0, *)
        private func makeAgent() -> Agent {
            let memory = self.settings.memoryEnabled ? self.makeMemoryStore() : nil
            let middlewares = self.makeMiddleware(memory: memory)
            var kits: [FoundationModelsToolKit] = [
                registerFoundationModelsTool(CurrentTimeTool()),
            ]
            if let memory {
                kits.append(registerFoundationModelsTool(
                    RememberTool(memoryStore: memory, namespace: AriaSampleConstants.memoryNamespace)
                ))
            }
            let provider: any LLMProvider = self.makeProvider(kits: kits)
            let toolsForAgent = provider.capabilities.supportsToolUse
                ? kits.map(\.anyTool)
                : []
            return Agent(config: AgentConfig(
                provider: provider,
                tools: toolsForAgent,
                systemPrompt: Self.systemPrompt(memoryEnabled: memory != nil),
                threadId: AriaSampleConstants.chatThreadId,
                middleware: middlewares
            ))
        }

        @available(iOS 26.0, macOS 26.0, *)
        private func makeProvider(kits: [FoundationModelsToolKit]) -> any LLMProvider {
            #if canImport(AriaMLX)
                if let mlx = self.appState.modelManager.makeProvider(
                    defaultInstructions: Self.systemPrompt(memoryEnabled: false)
                ) {
                    return mlx
                }
            #endif
            return FoundationModelsProvider(typedTools: kits.map(\.factory))
        }

        private func makeMemoryStore() -> (any MemoryStore)? {
            guard let embedder = NLEmbeddingEmbedder() else { return nil }
            let store = self.storage.vectorStore(dimensions: embedder.dimensions)
            return DefaultMemoryStore(embedder: embedder, store: store)
        }

        /// Builds the middleware chain off `AriaSettings`. Every knob
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
            var middlewares: [any AgentMiddleware] = [
                HistoryMiddleware(history: self.storage.chatHistory),
            ]
            #if canImport(FoundationModels)
                if #available(iOS 26.0, macOS 26.0, *), self.settings.summarizationEnabled {
                    middlewares.append(
                        HistorySummarizationMiddleware(
                            triggerAfterTurns: self.settings.summarizationTriggerTurns,
                            keepRecentTurns: self.settings.summarizationKeepRecentTurns,
                            summarizer: Self.makeAuxiliarySummarizer()
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
                let probe = self.memoryProbe
                middlewares.append(
                    RAGMiddleware(
                        memoryStore: memory,
                        namespace: AriaSampleConstants.memoryNamespace,
                        topK: self.settings.ragTopK,
                        onRecall: { matches in
                            let texts = matches.map(\.item.content)
                            Task { @MainActor in probe.lastRecalled = texts }
                        }
                    )
                )
                #if canImport(FoundationModels)
                    if #available(iOS 26.0, macOS 26.0, *), self.settings.factExtractionEnabled {
                        middlewares.append(
                            FactExtractionMiddleware(
                                memory: memory,
                                namespace: AriaSampleConstants.memoryNamespace,
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

        // MARK: - Auxiliary LLM helpers

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
                else { return [] }
                return array.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
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

        private static func systemPrompt(memoryEnabled: Bool) -> String {
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
        guard self.transcript.isEmpty else { return }
        do {
            let messages = try await self.storage.chatHistory.messages(
                threadId: AriaSampleConstants.chatThreadId
            )
            self.transcript = messages.compactMap(Self.transcriptItem(from:))
        } catch {
            self.transcript = [.assistant("Could not load history: \(error)")]
        }
    }

    @MainActor
    private func updateLastAssistant(text: String) {
        guard let lastIndex = transcript.indices.last,
              transcript[lastIndex].role == .assistant else { return }
        self.transcript[lastIndex].content = text
    }

    @MainActor
    private func clearHistory() async {
        do {
            try await self.storage.chatHistory.clear(threadId: AriaSampleConstants.chatThreadId)
            self.transcript = []
        } catch {
            self.transcript = [.assistant("Could not clear history: \(error)")]
        }
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

// TranscriptItemView removed — replaced by `MessageBubble` which renders
// the assistant avatar + uses the Niora-style bubble layout.
