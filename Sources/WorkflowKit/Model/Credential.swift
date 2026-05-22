import Foundation

// MARK: - Credential

/// User-owned credential for an external service (MCP server,
/// LLM provider, etc.). Metadata is persisted in
/// `UserDefaults`; the actual secret lives in the Keychain
/// keyed by `id`. Splitting the two lets us list credentials in
/// the picker without unlocking the Keychain just to render
/// their names.
///
/// Lives in `WorkflowKit` (rather than the app target) so the
/// engine-side resolver bridges can reference it without an
/// inverted-dependency import. The `CredentialStore`
/// (`@Observable` class consumed by SwiftUI) stays in the app.
public struct Credential: Codable, Identifiable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        notes: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.notes = notes
        self.createdAt = createdAt
    }

    // MARK: Public

    /// What shape the credential's secret takes. P0 ships
    /// `.apiToken` (single secret value) and `.basicAuth`
    /// (username + password packed as JSON). Both store one
    /// blob in the Keychain — the picker UI reads `kind` to
    /// decide which input fields to show.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case apiToken
        case basicAuth

        // MARK: Public

        public var displayName: String {
            switch self {
            case .apiToken: "API token"
            case .basicAuth: "Username + password"
            }
        }
    }

    public let id: UUID
    public var name: String
    public var kind: Kind
    public var notes: String?
    public let createdAt: Date
}

// MARK: - CredentialSecret

/// In-memory representation of the secret payload. `.apiToken`
/// holds a single string; `.basicAuth` holds a username +
/// password pair. The Keychain blob is the JSON encoding of
/// this enum — one entry per credential id.
public enum CredentialSecret: Codable, Sendable, Equatable {
    case apiToken(String)
    case basicAuth(username: String, password: String)

    // MARK: Public

    public var kind: Credential.Kind {
        switch self {
        case .apiToken: .apiToken
        case .basicAuth: .basicAuth
        }
    }
}
