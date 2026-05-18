import Aria
import AriaApple
import SwiftUI

#if canImport(FoundationModels)
    import FoundationModels
#endif

// MARK: - SuggestActivityScreen

/// Standalone demo of `Agent.respond(_:as:)`. Streams an
/// `ActivitySuggestion` and re-renders the partial snapshot in place
/// as each property fills in — the structured-output equivalent of a
/// "typewriter" UX.
///
/// Tool-free agent on purpose: registering tools alongside a
/// structured response can make the on-device model spin on tool
/// routing instead of producing snapshots.
@available(iOS 26.0, macOS 26.0, *)
struct SuggestActivityScreen: View {
    // MARK: Internal

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                Text(self.rendered)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.tertiarySystemBackground))
                    )
                    .padding()
            }
            Button {
                Task { await self.run() }
            } label: {
                Label(
                    self.isRunning ? "Generating…" : "Suggest activity",
                    systemImage: self.isRunning ? "hourglass" : "sparkles"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(self.isRunning)
            .padding(.horizontal)
            .padding(.bottom)
        }
        .navigationTitle("Suggest activity")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Private

    @State private var rendered: String = "Tap “Suggest activity” to stream a structured suggestion."
    @State private var isRunning = false

    private static func render(_ partial: ActivitySuggestion.PartiallyGenerated) -> String {
        let title = partial.title ?? "…"
        let summary = partial.summary ?? "…"
        let steps = partial.steps?.enumerated()
            .map { "  \($0.offset + 1). \($0.element)" }
            .joined(separator: "\n") ?? "  …"
        return "🎯 \(title)\n\n\(summary)\n\nSteps:\n\(steps)"
    }

    private static func render(_ suggestion: ActivitySuggestion) -> String {
        let steps = suggestion.steps.enumerated()
            .map { "  \($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        return "🎯 \(suggestion.title)\n\n\(suggestion.summary)\n\nSteps:\n\(steps)"
    }

    @MainActor
    private func run() async {
        self.isRunning = true
        defer { isRunning = false }
        self.rendered = "…"
        let agent = Agent(config: AgentConfig(
            provider: FoundationModelsProvider(),
            tools: [],
            systemPrompt: "Suggest one specific fun activity. Reply only via the structured response.",
            threadId: "suggest-demo"
        ))
        do {
            for try await event in agent.respond(
                .message(.user("Suggest a fun activity I could do today.")),
                as: ActivitySuggestion.self
            ) {
                switch event {
                case let .partial(snapshot):
                    self.rendered = Self.render(snapshot)
                case .toolCallExecuted:
                    break
                case let .finish(suggestion):
                    self.rendered = Self.render(suggestion)
                    return
                }
            }
        } catch {
            self.rendered = "Error: \(error)"
        }
    }
}
