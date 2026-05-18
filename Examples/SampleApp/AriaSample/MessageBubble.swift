import SwiftUI

// MARK: - MessageBubble

/// Niora-style chat bubble: user messages right-aligned with primary
/// tint; assistant messages left-aligned with a small AI avatar
/// rendered to the left of the bubble. Replaces the prior plain
/// `Text` bubble.
///
/// Grouping: when consecutive bubbles share a role, the avatar only
/// renders on the first bubble in the group; subsequent bubbles get
/// a transparent spacer of the same width so the text stays aligned.
struct MessageBubble: View {
    let item: TranscriptItem
    var isFirstInGroup: Bool = true

    var body: some View {
        switch self.item.role {
        case .user:
            self.userBubble
        case .assistant:
            self.assistantBubble
        }
    }

    private static let bubbleRadius: CGFloat = 18
    private static let avatarSize: CGFloat = 28

    private var userBubble: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 60)
            Text(self.item.content)
                .font(.body)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: Self.bubbleRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                )
        }
    }

    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            if self.isFirstInGroup {
                self.assistantAvatar
            } else {
                Color.clear.frame(width: Self.avatarSize, height: Self.avatarSize)
            }
            Text(LocalizedStringKey(self.item.content))
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: Self.bubbleRadius, style: .continuous)
                        .fill(Color(.tertiarySystemBackground))
                )
            Spacer(minLength: 40)
        }
    }

    /// Small circular avatar for the assistant, using SF Symbol so it
    /// blends with the system look and adapts to dark/light. Same
    /// shape Niora uses for its assistant bubbles minus the brand-
    /// specific gradient.
    private var assistantAvatar: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor, Color.purple.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.white)
        }
        .frame(width: Self.avatarSize, height: Self.avatarSize)
        .accessibilityHidden(true)
    }
}
