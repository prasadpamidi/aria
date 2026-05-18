import SwiftUI

// MARK: - ModelStatus

/// What the chat surface needs to communicate to the user about the
/// underlying provider's lifecycle, separately from what the response
/// bubble itself shows.
///
/// `.ready` means there's nothing to surface — the chat is idle or
/// the model is already producing tokens (the typing-dots inside the
/// assistant bubble already covers that).
///
/// `.preparing` is what saves us when a multi-gigabyte MLX model is
/// being decompressed from disk into memory for the first time this
/// session. Without an explicit pill the user sees a blank empty
/// bubble for 5–30 seconds and assumes the app hung.
enum ModelStatus: Equatable {
    case ready
    case preparing(label: String)
}

// MARK: - ModelStatusPill

/// Liquid-glass capsule that appears just above the input bar while
/// the active provider is initializing. Spinner so the user can tell
/// the app isn't frozen, and a *friendly* model name so they can see
/// what's taking its time — no quantization suffixes or "Instruct"
/// jargon.
///
/// Pinned in the same vertical strip as the quick-action chips and
/// input bar so the safe-area inset already accounts for it — no
/// extra layout fiddling needed.
struct ModelStatusPill: View {
    // MARK: Internal

    let status: ModelStatus

    var body: some View {
        switch self.status {
        case .ready:
            EmptyView()
        case let .preparing(label):
            // Capsule that hugs its content but caps at a maximum
            // width — long names wrap to a second/third line inside
            // the same pill instead of stretching it horizontally
            // across the screen. The pill is centered in the row by
            // the surrounding HStack with leading + trailing Spacers.
            HStack(alignment: .center, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)

                Text("Loading \(label)…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: 220, alignment: .leading)
            .contentShape(Capsule())
            .glassEffect(.regular, in: Capsule())
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    // MARK: Private

    /// Strip developer-jargon suffixes from the catalog displayName
    /// so the pill reads naturally:
    ///   "Qwen 3.5 4B (4-bit)"            → "Qwen 3.5 4B"
    ///   "Llama 3.2 3B Instruct (4-bit)"  → "Llama 3.2 3B"
    ///   "Apple Intelligence"             → "Apple Intelligence" (unchanged)
    private static func friendly(_ raw: String) -> String {
        var out = raw
        let strippableSuffixes = [
            " Instruct (4-bit)",
            " Instruct (8-bit)",
            " Instruct",
            " (4-bit)",
            " (8-bit)",
            " (mlx)",
        ]
        for suffix in strippableSuffixes {
            if let range = out.range(of: suffix, options: [.caseInsensitive, .backwards]) {
                out.removeSubrange(range)
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
