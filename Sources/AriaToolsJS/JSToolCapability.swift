import Foundation

// MARK: - JSToolCapability

/// One thing a JS-backed tool can do that touches the outside world.
/// Capabilities are declared up front in a tool's manifest; the
/// bridge object inside the tool's `JSContext` is built to bind only
/// the methods the manifest requested, so a tool that doesn't
/// declare `.http` literally can't `Aria.http.get(...)` — the
/// property is undefined.
///
/// **Permission-by-construction** rather than runtime checks: an
/// undeclared capability isn't enforced by an error at call time,
/// it's enforced by absence at object-construction time. Makes
/// review easier (manifest tells you everything the tool can do)
/// and makes accidental misuse impossible (calling an undefined
/// function in JS throws synchronously).
public enum JSToolCapability: String, Codable, Sendable, CaseIterable {
    /// `Aria.http.get(url)`, `Aria.http.post(url, body, opts)`.
    /// Routes through the same `HTTPClient` Swift-side `HTTPTool`
    /// uses, so behavior parity is automatic.
    case http

    /// `Aria.json.parse(text)`, `Aria.json.stringify(value)`.
    /// JavaScript has these natively; we expose Aria's `JSONValue`-
    /// safe variants for symmetry with the manifest schema layer.
    case json

    /// `Aria.clipboard.set(text)`, `Aria.clipboard.get()`.
    /// Reads/writes the system `UIPasteboard.general`.
    case clipboard

    /// `Aria.share.present({ text, url })`. Pushes a
    /// `UIActivityViewController` over the host app's key window.
    /// The tool can't customize the activity types — host policy.
    case share

    /// `Aria.notify.banner({ title, body })`. Schedules a local
    /// `UNUserNotificationCenter` notification with no trigger
    /// (delivered immediately). Requires the host app to have
    /// requested notification authorization.
    case notify

    /// `Aria.storage.set(key, value)`, `Aria.storage.get(key)`,
    /// `Aria.storage.delete(key)`. Per-tool key-value store backed
    /// by `UserDefaults` under a tool-id-scoped suite name. Tools
    /// can never read another tool's storage.
    case storage

    // MARK: Public

    public var displayName: String {
        switch self {
        case .http: "Internet access"
        case .json: "JSON parsing"
        case .clipboard: "Clipboard"
        case .share: "Share sheet"
        case .notify: "Notifications"
        case .storage: "Tool-local storage"
        }
    }

    /// Short one-line explanation for the install-time permission
    /// prompt UI. Reads as "this tool wants to …".
    public var userDescription: String {
        switch self {
        case .http: "make web requests"
        case .json: "parse and format JSON"
        case .clipboard: "read from and write to your clipboard"
        case .share: "open the system share sheet"
        case .notify: "post local notifications"
        case .storage: "save small amounts of data between uses"
        }
    }
}

// MARK: - Capability Set Helpers

extension Set<JSToolCapability> {
    /// Capabilities that surface a user-visible side effect (share
    /// sheet, notification, clipboard write). Used by the install
    /// UI to emphasize what the tool can do beyond reading data.
    public var userVisibleSideEffects: Set<JSToolCapability> {
        self.intersection([.share, .notify, .clipboard])
    }
}
