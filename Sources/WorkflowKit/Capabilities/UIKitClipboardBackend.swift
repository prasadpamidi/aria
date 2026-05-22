#if canImport(UIKit)
    import Foundation
    import UIKit

    // MARK: - UIKitClipboardBackend

    /// Production clipboard backend backed by `UIPasteboard.general`.
    /// Reads/writes happen on the main actor — UIPasteboard is
    /// documented as main-thread-safe but Apple's strict
    /// concurrency annotations vary across SDK versions, so we
    /// hop to MainActor explicitly to keep behaviour stable.
    ///
    /// iOS 14+: reading the pasteboard shows the user a "Pasted
    /// from Avyra" toast. No Info.plist key is required.
    public final class UIKitClipboardBackend: ClipboardBackend, @unchecked Sendable {
        // MARK: Lifecycle

        public init() { }

        // MARK: Public

        public func read() async -> String? {
            await MainActor.run {
                UIPasteboard.general.string
            }
        }

        public func write(_ text: String) async {
            await MainActor.run {
                UIPasteboard.general.string = text
            }
        }
    }
#endif
