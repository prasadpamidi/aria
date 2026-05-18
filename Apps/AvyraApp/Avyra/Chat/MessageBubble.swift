import MarkdownUI
import SwiftUI

// MARK: - MessageBubble

/// Niora-style chat bubble. User messages right-aligned with primary
/// tint; assistant messages left-aligned with avatar + optional
/// accessory pills above (thinking, recalled memories, tool calls).
///
/// Grouping: consecutive same-role bubbles render the avatar only on
/// the first; subsequent ones get a transparent spacer of equal
/// width so the text alignment stays consistent.
struct MessageBubble: View {
    // MARK: Internal

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

    // MARK: Private

    private static let bubbleRadius: CGFloat = 18
    private static let avatarSize: CGFloat = 28

    @Environment(\.avyraSettings) private var settings

    /// Parsed view of the streamed text + per-turn metadata. Re-runs
    /// on every render — cheap, and `<think>` parsing needs the
    /// latest text since the closing tag can arrive on any token.
    private var parsed: ParsedAssistantContent {
        MessageContentParser.parse(
            raw: self.item.content,
            toolCalls: self.item.toolCalls,
            recalledMemories: self.item.recalledMemories,
            expectsThinking: self.item.expectsThinking
        )
    }

    // MARK: - User

    private var userBubble: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 6) {
                if !self.item.attachedImages.isEmpty {
                    self.attachmentStrip
                }
                if !self.item.content.isEmpty {
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
        }
    }

    /// Right-aligned strip of thumbnails the user attached to this
    /// turn. Caps width via `maxThumbnailRowWidth` so a 6-image batch
    /// still leaves room for the avatar gutter on the left.
    private var attachmentStrip: some View {
        let images = self.item.attachedImages
        let count = images.count
        return HStack(spacing: 6) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, data in
                if let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(
                            width: count == 1 ? 180 : 80,
                            height: count == 1 ? 180 : 80
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                        )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count == 1 ? "1 attached image" : "\(count) attached images")
    }

    // MARK: - Assistant

    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            if self.isFirstInGroup {
                self.assistantAvatar
            } else {
                Color.clear.frame(width: Self.avatarSize, height: Self.avatarSize)
            }
            VStack(alignment: .leading, spacing: 6) {
                // Tool-call pills are developer-mode only — a regular
                // user shouldn't see "remember_fact" badges above the
                // assistant's reply.
                if self.settings.developerModeEnabled, !self.parsed.toolCalls.isEmpty {
                    self.toolCallPills
                }
                // Thinking pill is *always* shown — it tells the
                // user the model is reasoning (active animation
                // while mid-thinking, static "Show reasoning" once
                // the model finishes thinking and starts replying).
                // Tap-to-expand is gated on developer mode so a
                // regular user just sees the status, while a dev
                // can inspect the chain of thought.
                if let thinking = parsed.thinking, !thinking.isEmpty {
                    ThinkingPill(
                        content: thinking,
                        isInProgress: self.parsed.thinkingInProgress,
                        allowExpand: self.settings.developerModeEnabled
                    )
                }
                // Recall chip is also developer-only; the memory it
                // surfaced has already shaped the reply.
                if self.settings.developerModeEnabled, !self.parsed.recalledMemories.isEmpty {
                    self.recallPill
                }
                // Partial body the stream produced before failing
                // still renders above the error card so the user
                // doesn't lose context.
                if !self.parsed.visible.isEmpty {
                    self.bubbleBody
                }
                if let error = self.item.error {
                    ErrorCard(
                        error: error,
                        showTechnicalDetails: self.settings.developerModeEnabled
                    )
                } else if self.parsed.visible.isEmpty {
                    // Empty + no error means the stream hasn't
                    // produced anything yet — show the typing dots.
                    self.bubbleBody
                }
            }
            Spacer(minLength: 40)
        }
    }

    /// Body of the assistant bubble — typing dots when there's no
    /// visible text yet (model is generating, or only thinking
    /// tokens have arrived); the streamed text once visible content
    /// arrives.
    @ViewBuilder
    private var bubbleBody: some View {
        if self.parsed.visible.isEmpty {
            // Show the typing indicator unless we have NOTHING to
            // render (no thinking either) — when thinking is present
            // the user already sees movement.
            if self.parsed.thinking == nil {
                TypingIndicator()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: Self.bubbleRadius, style: .continuous)
                            .fill(Color(.tertiarySystemBackground))
                    )
            }
        } else {
            // Full GitHub-flavored markdown via `MarkdownUI`:
            // headings, lists, tables, fenced code blocks with
            // syntax highlighting, blockquotes, task lists, etc.
            // Replaces the old `Text(LocalizedStringKey(...))` path
            // which only honored a sliver of inline markdown
            // (`**bold**`, `*italic*`, links) and rendered code
            // fences as literal backticks.
            Markdown(self.parsed.visible)
                .markdownTheme(.avyraChat)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: Self.bubbleRadius, style: .continuous)
                        .fill(Color(.tertiarySystemBackground))
                )
        }
    }

    private var toolCallPills: some View {
        HStack(spacing: 6) {
            ForEach(Array(self.parsed.toolCalls.enumerated()), id: \.offset) { _, name in
                Label(name, systemImage: "wrench.and.screwdriver")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color(.tertiarySystemBackground))
                    )
            }
        }
    }

    private var recallPill: some View {
        let count = self.parsed.recalledMemories.count
        return Label(
            "Recalled \(count) memor\(count == 1 ? "y" : "ies")",
            systemImage: "brain.head.profile"
        )
        .labelStyle(.titleAndIcon)
        .font(.caption2.weight(.medium))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.accentColor.opacity(0.12))
        )
    }

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

// MARK: - ThinkingPill

/// Reasoning-status pill that appears above the assistant bubble
/// whenever a reasoning model is in flight or has produced
/// reasoning content.
///
///   - **In progress** (`isInProgress == true`): "Thinking…" with
///     three animated dots, accent-tinted. Tells the user the
///     model is actively reasoning before it starts replying.
///   - **Done** (`isInProgress == false`): "Reasoning" with a
///     chevron — implies the model finished thinking and the
///     reasoning is available to review.
///
/// `allowExpand` gates the tap-to-expand interaction on developer
/// mode. Non-dev users see the pill as a non-interactive status
/// chip; devs can tap to read the chain of thought.
private struct ThinkingPill: View {
    // MARK: Internal

    let content: String
    var isInProgress: Bool = false
    var allowExpand: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if self.allowExpand {
                Button {
                    withAnimation(.snappy(duration: 0.18)) { self.expanded.toggle() }
                } label: {
                    self.pillContent
                }
                .buttonStyle(.plain)
            } else {
                // Non-interactive — chevron hidden because there's
                // no tap target to reveal.
                self.pillContent
            }

            if self.allowExpand, self.expanded {
                Text(self.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.tertiarySystemBackground).opacity(0.5))
                    )
            }
        }
    }

    // MARK: Private

    @State private var expanded = false

    private var labelText: String {
        if self.isInProgress {
            return "Thinking"
        }
        return self.expanded ? "Hide reasoning" : "Reasoning"
    }

    /// The pill's visible chip — same shape whether interactive or
    /// not, just different content depending on
    /// `isInProgress` / `allowExpand` / `expanded`.
    private var pillContent: some View {
        HStack(spacing: 6) {
            Image(systemName: self.isInProgress ? "brain.head.profile" : "brain")
                .font(.caption2)
                .foregroundStyle(self.isInProgress ? Color.accentColor : .secondary)
                .symbolEffect(
                    .pulse,
                    options: .repeating,
                    isActive: self.isInProgress
                )
            Text(self.labelText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(self.isInProgress ? Color.accentColor : .secondary)
            if self.isInProgress {
                ThinkingDots()
                    .foregroundStyle(Color.accentColor)
            } else if self.allowExpand {
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .rotationEffect(.degrees(self.expanded ? 180 : 0))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(
                self.isInProgress
                    ? Color.accentColor.opacity(0.12)
                    : Color(.tertiarySystemBackground)
            )
        )
    }
}

// MARK: - ThinkingDots

/// Three little animated dots that ride next to the "Thinking…"
/// text. Loops indefinitely; the parent removes it when the model
/// stops reasoning.
private struct ThinkingDots: View {
    // MARK: Internal

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 3, height: 3)
                    .opacity(self.phase == index ? 1.0 : 0.25)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                // Trick to drive the discrete phase change via a
                // continuous timer — the `onChange` below picks up
                // the modulo and updates `phase`.
            }
            self.startTicking()
        }
    }

    // MARK: Private

    @State private var phase = 0

    private func startTicking() {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation(.smooth(duration: 0.15)) {
                    self.phase = (self.phase + 1) % 3
                }
            }
        }
    }
}
