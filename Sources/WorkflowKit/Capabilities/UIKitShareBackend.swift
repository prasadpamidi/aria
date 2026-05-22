import Foundation
#if canImport(UIKit)
    import UIKit

    // MARK: - UIKitShareBackend

    /// Production share-sheet backend. Walks the connected
    /// `UIScene`s on every call to find the topmost presented
    /// view controller — the workflow run sheet (or whatever
    /// SwiftUI surface kicked off the workflow) is the natural
    /// presenter. A custom resolver can be injected for tests
    /// or for surfacing the sheet from a non-standard window.
    public final class UIKitShareBackend: ShareBackend, @unchecked Sendable {
        // MARK: Lifecycle

        public init(presenter: @escaping PresenterResolver = UIKitShareBackend.defaultPresenter) {
            self.presenter = presenter
        }

        // MARK: Public

        public typealias PresenterResolver = @MainActor @Sendable () -> UIViewController?

        @MainActor
        public static func defaultPresenter() -> UIViewController? {
            // iOS 13+ multi-scene world: pick the first
            // foreground-active scene's key window, then walk
            // up its presented chain. Falls back to any window
            // scene if none are foreground-active (e.g.
            // multitasking).
            let scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
            var top = window?.rootViewController
            while let presented = top?.presentedViewController {
                top = presented
            }
            return top
        }

        public func share(text: String) async throws -> Bool {
            try await self.shareOnMain(text)
        }

        // MARK: Private

        private let presenter: PresenterResolver

        @MainActor
        private func shareOnMain(_ text: String) async throws -> Bool {
            guard let presenter = self.presenter() else {
                throw ShareError.noPresenter
            }
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
                activity.completionWithItemsHandler = { _, completed, _, _ in
                    continuation.resume(returning: completed)
                }
                // iPad: popover presentation needs a source rect.
                // Anchor to the presenter view's center; permitted
                // arrow directions cleared so it renders as a
                // centred popover instead of pointing at a
                // tap target.
                if let popover = activity.popoverPresentationController {
                    popover.sourceView = presenter.view
                    popover.sourceRect = CGRect(
                        x: presenter.view.bounds.midX,
                        y: presenter.view.bounds.midY,
                        width: 0,
                        height: 0
                    )
                    popover.permittedArrowDirections = []
                }
                presenter.present(activity, animated: true)
            }
        }
    }
#endif

// MARK: - ShareError

/// Failure modes for the share capability. Available on every
/// platform so the engine's typed-error switch doesn't need
/// `#if canImport(UIKit)` guards.
public enum ShareError: LocalizedError, Sendable, Equatable {
    case noPresenter

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case .noPresenter:
            "No window available to present the share sheet. Trigger the workflow from inside the app and try again."
        }
    }
}
