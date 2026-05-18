import SwiftUI
import UIKit

// MARK: - ErrorCard

/// Replaces the assistant text bubble when the provider stream
/// failed for that turn. Always shows the friendly summary (and
/// optional hint). When `showTechnicalDetails` is true (developer
/// mode), it adds a "Show technical details" disclosure that reveals
/// the raw error dump in monospaced text with a one-tap copy button —
/// useful for filing bug reports without forcing developers to dig
/// into Console.
///
/// Visually distinct from a normal bubble: orange exclamation icon,
/// orange-tinted background, no avatar gradient, no markdown render.
/// Reads as "something went wrong" at a glance.
struct ErrorCard: View {
    // MARK: Internal

    let error: AssistantError
    var showTechnicalDetails: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.body)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.error.friendly)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if !self.error.hint.isEmpty {
                        Text(self.error.hint)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if self.showTechnicalDetails {
                self.detailsSection
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.orange.opacity(0.30), lineWidth: 1)
        )
    }

    // MARK: Private

    @State private var detailsExpanded = false
    @State private var copyConfirmation = false

    /// Developer-only disclosure. Reveals the full raw error dump so
    /// devs can copy + paste into a bug report. Hidden from users by
    /// default — they don't need to see NSError userInfo dicts.
    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { self.detailsExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(self.detailsExpanded ? 0 : -90))
                    Text(self.detailsExpanded ? "Hide technical details" : "Show technical details")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if self.detailsExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(self.error.technical)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 200)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.tertiarySystemBackground))
                    )

                    HStack(spacing: 8) {
                        Button {
                            UIPasteboard.general.string = self.error.technical
                            self.copyConfirmation = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                self.copyConfirmation = false
                            }
                        } label: {
                            Label(
                                self.copyConfirmation ? "Copied" : "Copy",
                                systemImage: self.copyConfirmation ? "checkmark" : "doc.on.doc"
                            )
                            .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        ShareLink(item: self.error.technical) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
    }
}
