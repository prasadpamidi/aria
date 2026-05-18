import AriaApple
import SwiftUI

#if canImport(AriaMLX)
    import AriaMLX
#endif

// MARK: - ChatHeader

/// Slim glass-effect header for the chat screen — mirrors Niora's
/// `SessionTopBar` pattern. Two affordances:
///
/// - **Model pill (left)** — tappable capsule showing the active
///   provider; opens `ModelPickerSheet` for swapping between
///   FoundationModels and any installed MLX model.
/// - **Actions menu (right)** — small circle button for less-frequent
///   actions (clear chat, etc.).
///
/// Replaces the heavy NavigationStack large-title + ellipsis combo
/// from the prior version so the chat surface gets the vertical
/// space it deserves.
struct ChatHeader: View {
    // MARK: Internal

    let providerLabel: String
    let memoryEnabled: Bool
    let onPickModel: () -> Void
    let onClearChat: () -> Void
    let isStreaming: Bool
    let canClearChat: Bool

    var body: some View {
        HStack(spacing: 8) {
            self.modelPill
                .accessibilityIdentifier("Chat.Header.ModelPicker")
            Spacer(minLength: 8)
            if !self.memoryEnabled {
                self.memoryOffBadge
            }
            self.actionsMenu
                .accessibilityIdentifier("Chat.Header.Actions")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: Private

    /// Tappable capsule showing the active provider. Single-tap
    /// surfaces the model picker so users can swap models without
    /// diving into Settings.
    private var modelPill: some View {
        Button(action: self.onPickModel) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.caption2)
                Text(self.providerLabel)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(self.isStreaming)
    }

    private var memoryOffBadge: some View {
        Label("memory off", systemImage: "brain.head.profile")
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color(.tertiarySystemBackground))
            )
    }

    /// Compact glass-circle for secondary actions. Same shape Niora
    /// uses for its top-bar close button.
    private var actionsMenu: some View {
        Menu {
            Button(role: .destructive, action: self.onClearChat) {
                Label("Clear chat", systemImage: "trash")
            }
            .disabled(!self.canClearChat)
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline)
                .frame(width: 32, height: 32)
                .glassEffect(.regular, in: Circle())
                .accessibilityHidden(true)
        }
        .accessibilityLabel("Actions")
        .disabled(self.isStreaming)
    }
}
