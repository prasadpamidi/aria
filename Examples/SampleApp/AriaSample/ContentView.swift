import Aria
import AriaApple
import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    // MARK: Internal

    var body: some View {
        VStack(spacing: 0) {
            self.header
            self.messageList
            self.inputBar
        }
        .background(Color(.systemBackground))
    }

    // MARK: Private

    @State private var input: String = ""
    @State private var transcript: [TranscriptItem] = []
    @State private var isStreaming: Bool = false

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

    @MainActor
    private func send() async {
        let trimmed = self.input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return
        }

        self.transcript.append(.user(trimmed))
        self.input = ""
        self.isStreaming = true
        defer { isStreaming = false }

        // Conversation history seen so far, plus the new user message.
        // PR 2 sends only single-turn history — multi-turn arrives with the
        // agent loop in PR 3. The mapping below preserves prior turns so the
        // model has context.
        let history = self.transcript.map { item in
            switch item.role {
            case .user: Message.user(item.content)
            case .assistant: Message.assistant(item.content)
            }
        }
        let messages: [Message] =
            [.system("You are a concise, helpful assistant.")] + history

        let provider = FoundationModelsProvider()
        var assistantText = ""
        self.transcript.append(.assistant(""))

        do {
            for try await event in provider.stream(
                messages: messages,
                tools: [],
                options: .init()
            ) {
                switch event {
                case let .textDelta(chunk):
                    assistantText += chunk
                    self.updateLastAssistant(text: assistantText)
                case .messageStop:
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
    ContentView()
}
