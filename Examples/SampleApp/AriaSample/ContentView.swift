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
                Text("Aria \(Aria.version)  ·  AriaApple \(AriaApple.version)")
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

        // ┌────────────────────────────────────────────────────────────────┐
        // │ TARGET API — uncomment once Aria & AriaApple are implemented:  │
        // ├────────────────────────────────────────────────────────────────┤
        //
        // let agent = Agent(config: AgentConfig(
        //     provider: FoundationModelsProvider(model: .systemDefault),
        //     tools: [],
        //     systemPrompt: "You are a concise, helpful assistant."
        // ))
        //
        // var assistantText = ""
        // transcript.append(.assistant(""))
        //
        // do {
        //     for try await event in agent.stream(.message(.user(trimmed)), options: .init()) {
        //         switch event {
        //         case .textDelta(let chunk):
        //             assistantText += chunk
        //             if var last = transcript.last, last.role == .assistant {
        //                 last.content = assistantText
        //                 transcript[transcript.count - 1] = last
        //             }
        //         case .toolCallRequested(let call):
        //             _ = call    // surface a tool badge — exercise for the reader
        //         case .finish:
        //             return
        //         case .error(let err):
        //             transcript.append(.assistant("Error: \(err)"))
        //             return
        //         default:
        //             break
        //         }
        //     }
        // } catch {
        //     transcript.append(.assistant("Error: \(error.localizedDescription)"))
        // }
        //
        // └────────────────────────────────────────────────────────────────┘

        // Placeholder behavior until implementation lands:
        try? await Task.sleep(for: .milliseconds(400))
        self.transcript.append(.assistant("(Aria \(Aria.version) — implementation pending. Echo: \(trimmed))"))
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
