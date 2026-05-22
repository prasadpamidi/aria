import Foundation

// MARK: - MCPError

/// Closed set of failure modes the MCP client surfaces. Each
/// carries enough context for the Run sheet's error banner to
/// render an actionable message instead of an opaque protocol
/// code — MCP servers reply with structured errors but the
/// transport itself fails in mundane HTTP / JSON-RPC ways.
public enum MCPError: LocalizedError, Sendable, Equatable {
    /// The configured server URL didn't parse as a URL.
    case invalidServerURL(String)
    /// `URLSession` returned a non-2xx response. Carries the
    /// status code + a short excerpt of the body so a 401 / 403
    /// from a reverse-proxy reads as "auth failed" instead of
    /// "request failed".
    case httpStatus(code: Int, bodyExcerpt: String)
    /// The server returned 2xx but the body didn't parse as
    /// JSON-RPC 2.0. Carries the JSON-pointer-ish description
    /// of what we couldn't find.
    case malformedResponse(String)
    /// MCP server returned a JSON-RPC error envelope. Carries
    /// the server's `code` + `message` so the user sees the
    /// vendor's diagnostic verbatim (`Tool 'foo' not found`,
    /// `Invalid params`, etc.).
    case serverError(code: Int, message: String)
    /// The step named a credential id but the resolver returned
    /// nil — usually the credential was deleted between save
    /// time and run time. Distinct from "no credentialID" (which
    /// is a valid "open server" configuration).
    case missingCredential(UUID)
    /// Network failure (offline, DNS, timeout). Wraps the
    /// underlying URLError's `localizedDescription`.
    case networkFailure(String)

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case let .invalidServerURL(raw):
            "The MCP server URL `\(raw)` isn't a valid URL. Fix it in the step's editor."
        case let .httpStatus(code, body):
            "MCP server returned HTTP \(code). \(body)"
        case let .malformedResponse(detail):
            "MCP server reply didn't match JSON-RPC 2.0. \(detail)"
        case let .serverError(code, message):
            "MCP server reported error \(code): \(message)"
        case let .missingCredential(id):
            "The credential \(id.uuidString) referenced by this step isn't available. Recreate it under Settings → Credentials or pick a different one in the step's editor."
        case let .networkFailure(message):
            "Network error reaching the MCP server: \(message)"
        }
    }
}
