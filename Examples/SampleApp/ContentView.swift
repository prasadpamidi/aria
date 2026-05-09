// Aria Sample App — ContentView.swift
//
// Drop this into a new Xcode iOS App project that depends on the Aria
// Swift Package. See README.md in this folder for setup steps.
//
// This file demonstrates Aria's intended API. It compiles against the
// scaffolding in the current Aria package; the actual agent calls are
// commented out where they reference types pending implementation.

import SwiftUI
import Aria
// import AriaApple   // uncomment once AriaApple implementations land
// import AriaTools   // uncomment when consumer tools are needed

struct ContentView: View {
    @State private var input: String = ""
    @State private var transcript: [TranscriptItem] = []
    @State private var isStreaming: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
            inputBar
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Aria Sample")
                    .font(.headline)
                Text("v\(Aria.version)")
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
                    ForEach(transcript) { item in
                        TranscriptItemView(item: item)
                            .id(item.id)
                    }
                }
                .padding()
            }
            .onChange(of: transcript.count) { _, _ in
                if let last = transcript.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask anything…", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(isStreaming)

            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || isStreaming)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - Actions

    @MainActor
    private func send() async {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        transcript.append(.user(trimmed))
        input = ""
        isStreaming = true
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
        //             // Show a tool badge — left as an exercise.
        //             _ = call
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
        transcript.append(.assistant("(Aria implementation pending — sample app placeholder.)"))
    }
}

// MARK: - Local types

struct TranscriptItem: Identifiable {
    let id = UUID()
    var role: Role
    var content: String

    enum Role { case user, assistant }

    static func user(_ text: String) -> TranscriptItem {
        .init(role: .user, content: text)
    }

    static func assistant(_ text: String) -> TranscriptItem {
        .init(role: .assistant, content: text)
    }
}

struct TranscriptItemView: View {
    let item: TranscriptItem

    var body: some View {
        HStack(alignment: .top) {
            if item.role == .assistant {
                bubble
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                bubble
            }
        }
    }

    private var bubble: some View {
        Text(item.content)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(item.role == .user
                          ? Color.accentColor.opacity(0.15)
                          : Color(.tertiarySystemBackground))
            )
    }
}

#Preview {
    ContentView()
}
