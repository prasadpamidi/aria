import Foundation
#if canImport(UIKit)
    import UIKit

    // MARK: - UIKitShortcutsBackend

    /// Production Shortcuts-invocation backend. Constructs the
    /// `shortcuts://run-shortcut?name=…&input=…` URL and asks
    /// `UIApplication.shared` to open it, which hands control
    /// to the Shortcuts app. Completion isn't observed —
    /// Shortcuts publishes its own `x-callback-url` for that
    /// but the URL launch itself fires async on iOS, so the
    /// workflow gets a "launched" boolean and continues.
    public final class UIKitShortcutsBackend: ShortcutsBackend, @unchecked Sendable {
        // MARK: Lifecycle

        public init() { }

        // MARK: Public

        public func run(name: String, input: String?) async throws -> Bool {
            guard let url = Self.buildURL(name: name, input: input) else {
                return false
            }
            return await MainActor.run {
                guard UIApplication.shared.canOpenURL(url) else {
                    return false
                }
                // `open(_:options:completionHandler:)` is the
                // documented Sendable path; the completion
                // handler reports launch success, not whether
                // the Shortcut actually completed.
                Self.openURL(url)
                return true
            }
        }

        // MARK: Private

        @MainActor
        private static func openURL(_ url: URL) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }

        private static func buildURL(name: String, input: String?) -> URL? {
            var components = URLComponents()
            components.scheme = "shortcuts"
            components.host = "run-shortcut"
            var items: [URLQueryItem] = [URLQueryItem(name: "name", value: name)]
            if let input, !input.isEmpty {
                items.append(URLQueryItem(name: "input", value: input))
            }
            components.queryItems = items
            return components.url
        }
    }
#endif
