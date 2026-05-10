import Aria
import AriaApple
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
    }

    // MARK: Private

    private static let threadId = "default"
    private static let memoryNamespace = ["sample", "default"]

    @State private var input: String = ""
    @State private var transcript: [TranscriptItem] = []
    @State private var isStreaming: Bool = false

    private let storage: GRDBStorage

    // MARK: - Subviews

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Aria Sample")
                    .font(.headline)
                Text("Aria \(AriaInfo.version)  ·  AriaApple \(AriaApple.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
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
        HStack(spacing: 8) {
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
            .disabled(self.input.trimmingCharacters(in: .whitespaces).isEmpty || self.isStreaming)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
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
        guard !trimmed.isEmpty else {
            return
        }

        let userMessage = trimmed
        self.transcript.append(.user(userMessage))
        self.input = ""
        self.isStreaming = true
        defer { isStreaming = false }

        self.transcript.append(.assistant(""))
        await self.runAgent(userMessage: userMessage)
    }

    @MainActor
    private func runAgent(userMessage: String) async {
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
        private func streamWithAgent(userMessage: String) async {
            let agent = self.makeAgent()
            var assistantText = ""
            do {
                for try await event in agent.stream(.message(.user(userMessage))) {
                    switch event {
                    case let .textDelta(chunk):
                        assistantText += chunk
                        self.updateLastAssistant(text: assistantText)
                    case let .toolCallRequested(call):
                        let badge = "[calling \(call.name)]"
                        assistantText = self.withInlineBadge(assistantText, badge: badge)
                        self.updateLastAssistant(text: assistantText)
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

        @available(iOS 26.0, macOS 26.0, *)
        private func makeAgent() -> Agent {
            let memory = self.makeMemoryStore()
            let middlewares = self.makeMiddleware(memory: memory)
            var tools: [AnyTool] = [AnyTool(CurrentTimeTool())]
            if let memory {
                tools.append(
                    AnyTool(RememberTool(memoryStore: memory, namespace: Self.memoryNamespace))
                )
            }
            return Agent(config: AgentConfig(
                provider: FoundationModelsProvider(),
                tools: tools,
                systemPrompt: Self.systemPrompt(memoryEnabled: memory != nil),
                threadId: Self.threadId,
                middleware: middlewares
            ))
        }

        /// Returns a configured `MemoryStore`, or `nil` when the OS does
        /// not ship an `NLEmbedding` for the chosen language. The sample
        /// degrades gracefully — agent + history still work.
        private func makeMemoryStore() -> (any MemoryStore)? {
            guard let embedder = NLEmbeddingEmbedder() else {
                return nil
            }
            let store = InMemoryVectorStore(dimensions: embedder.dimensions)
            return DefaultMemoryStore(embedder: embedder, store: store)
        }

        private func makeMiddleware(memory: (any MemoryStore)?) -> [any AgentMiddleware] {
            var middlewares: [any AgentMiddleware] = [
                HistoryMiddleware(history: self.storage.chatHistory),
            ]
            if let memory {
                middlewares.append(
                    RAGMiddleware(memoryStore: memory, namespace: Self.memoryNamespace, topK: 4)
                )
            }
            return middlewares
        }

        private static func systemPrompt(memoryEnabled: Bool) -> String {
            var lines: [String] = [
                "You are a concise, helpful assistant.",
                "When the user asks about the current time or date, call the current_time tool.",
            ]
            if memoryEnabled {
                lines.append(
                    "When the user shares a durable preference, biographical fact, or "
                        + "anything they will want you to remember in the future, call the "
                        + "remember_fact tool with a single concise sentence."
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
