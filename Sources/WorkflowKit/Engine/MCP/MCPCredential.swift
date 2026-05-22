import Foundation

// MARK: - MCPCredential

/// Authentication payload for an MCP server connection,
/// resolved per-step from the user's credential vault. The app
/// converts a `CredentialSecret` (`.apiToken` / `.basicAuth`)
/// into one of these so the engine never imports the credential
/// types directly — `WorkflowKit` stays storage-agnostic.
///
/// `bearer` covers the common case (an OAuth token, GitHub PAT,
/// or service-specific API key sent via `Authorization: Bearer`).
/// `basic` covers HTTP Basic auth — MCP servers behind a
/// reverse-proxy that wants RFC 7617 still work without special
/// casing in the step.
public enum MCPCredential: Sendable, Equatable {
    case bearer(String)
    case basic(username: String, password: String)
}

// MARK: - MCPCredentialResolver

/// Closure injected into `WorkflowCompiler` that turns a saved
/// credential id (from `MCPToolStep.credentialID`) into the
/// `MCPCredential` payload the client uses at request time. The
/// app builds the closure with access to its `CredentialStore`,
/// hops to the main actor as needed, and pulls the secret
/// out of the Keychain right when the step fires.
///
/// Returning `nil` lets the step run without auth — useful for
/// MCP servers on a private network that don't require a token.
/// A step that DOES name a credentialID but resolves to `nil`
/// (deleted credential, missing Keychain entry) surfaces a
/// `MCPError.missingCredential` at call time rather than silently
/// sending an unauthenticated request.
public typealias MCPCredentialResolver = @Sendable (UUID) async -> MCPCredential?
