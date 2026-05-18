import SwiftUI

// MARK: - QuickActionChips

/// Horizontal scrolling row of starter prompts pinned just above the
/// input bar. Tapping a chip loads its text into the input field,
/// focuses it, and lets the user edit before sending — a one-tap
/// onboarding aid for users staring at an empty chat.
///
/// The chips disappear once the conversation has any messages so
/// they don't keep nagging mid-conversation; a fresh "new chat"
/// brings them back.
struct QuickActionChips: View {
    // MARK: Internal

    let prompts: [String]
    let isStreaming: Bool
    let onPick: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(self.prompts, id: \.self) { prompt in
                    self.chip(prompt)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .frame(height: 64)
    }

    // MARK: Private

    private func chip(_ prompt: String) -> some View {
        Button {
            self.onPick(prompt)
        } label: {
            Text(prompt)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(self.isStreaming)
    }
}

// MARK: - Defaults

extension QuickActionChips {
    /// Friendly starter prompts a real user might actually tap on a
    /// fresh chat. Mix of memory, planning, casual, and curiosity so
    /// there's something for whoever opens the app — kept free of
    /// developer/internal jargon (no `@Generable`, no "tool calls"
    /// etc.) since this is the first thing a non-technical user sees.
    static let starterPrompts: [String] = [
        "What can you help me with?",
        "Tell me a fun fact",
        "Remember I prefer metric units",
        "Help me plan my day",
        "Give me a quick recipe idea",
        "Summarize a topic for me",
    ]
}
