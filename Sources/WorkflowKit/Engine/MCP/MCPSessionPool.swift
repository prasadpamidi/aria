import Foundation
import MCP

// MARK: - MCPSessionKey

/// Identity of a poolable session.
///
/// The credential is part of the key because the `Authorization` header
/// is baked into the transport when it is built — a refreshed OAuth
/// token cannot reuse the old transport, it needs a new one. Keying on
/// a fingerprint rather than the credential itself keeps secrets out of
/// dictionary keys and out of any future debug description.
struct MCPSessionKey: Hashable {
    let endpoint: URL
    let credentialFingerprint: Int
    let clientName: String
    let clientVersion: String
}

// MARK: - MCPSessionPool

/// Keeps one connected MCP client per server, instead of standing up a
/// fresh one for every call.
///
/// The client this replaced ran a full `initialize` handshake per
/// request and tore the transport down afterwards, with a comment
/// claiming this "matches MCP's session-per-call model". MCP has no
/// such model: it is a stateful session protocol — `initialize`, then
/// operate, then shut down — and Streamable HTTP carries an
/// `Mcp-Session-Id` across the session. Reconnecting per call meant:
///
///   * a handshake on every tool call, so a turn calling three tools
///     paid three;
///   * any server holding per-session state (a cache, a cursor, an auth
///     context) seeing each call as a brand-new session, and
///     misbehaving quietly rather than erroring.
///
/// Sessions are evicted after `idleTimeout` so a server that is used
/// once in a conversation does not hold a connection open for the life
/// of the process.
actor MCPSessionPool {
    // MARK: Internal

    static let shared = MCPSessionPool()

    /// Run `body` against a connected client for `key`, reusing an
    /// existing session when one is live.
    ///
    /// Retries **once** on a connection-shaped failure. A pooled
    /// connection can be closed by the server, a proxy, or the OS
    /// between calls, and the caller cannot distinguish "the session
    /// went stale" from "this request is bad" — so the pool absorbs it.
    /// The retry is deliberately not a general one: a `serverError` is
    /// the server answering, and answering twice would be wrong.
    /// `makeTransport` is a factory rather than a value because a
    /// retry needs a *fresh* transport — a disconnected one cannot be
    /// reconnected. Taking `any Transport` also lets tests drive the
    /// pool without a live server.
    func withClient<T: Sendable>(
        key: MCPSessionKey,
        makeTransport: @Sendable () -> any Transport,
        body: @Sendable (Client) async throws -> T
    ) async throws -> T {
        self.evictExpired()
        do {
            let client = try await self.connectedClient(for: key, makeTransport: makeTransport)
            let value = try await body(client)
            self.sessions[key]?.touch()
            return value
        } catch {
            guard Self.isConnectionFailure(error) else {
                throw error
            }
            await self.drop(key)
            let client = try await self.connectedClient(for: key, makeTransport: makeTransport)
            let value = try await body(client)
            self.sessions[key]?.touch()
            return value
        }
    }

    /// Close every session. Call when the host app backgrounds — an
    /// open connection across a suspension is a connection that will be
    /// found dead on resume, and paying the reconnect at that point is
    /// cheaper than discovering it mid-turn.
    func closeAll() async {
        let live = self.sessions.values
        self.sessions.removeAll()
        for session in live {
            await session.client.disconnect()
        }
    }

    /// Drop one session — used after an auth change or a failure.
    func drop(_ key: MCPSessionKey) async {
        guard let session = self.sessions.removeValue(forKey: key) else {
            return
        }
        await session.client.disconnect()
    }

    // MARK: Private

    private final class Session {
        // MARK: Lifecycle

        init(client: Client) {
            self.client = client
            self.lastUsed = Date()
        }

        // MARK: Internal

        let client: Client
        private(set) var lastUsed: Date

        func touch() {
            self.lastUsed = Date()
        }
    }

    /// Long enough to cover a conversational turn and the follow-up
    /// that usually accompanies it; short enough that an app left open
    /// on a screen is not holding sockets to every configured server.
    private static let idleTimeout: TimeInterval = 180

    private var sessions: [MCPSessionKey: Session] = [:]

    /// Connection-shaped failures, worth one retry on a fresh session.
    /// A `serverError` is excluded on purpose: the server responded,
    /// and repeating a request it already answered risks doing a
    /// non-idempotent thing twice.
    private static func isConnectionFailure(_ error: Error) -> Bool {
        if let sdk = error as? MCP.MCPError {
            switch sdk {
            case .connectionClosed, .transportError:
                return true
            default:
                return false
            }
        }
        if let ours = error as? MCPError, case .networkFailure = ours {
            return true
        }
        return false
    }

    private func connectedClient(
        for key: MCPSessionKey,
        makeTransport: @Sendable () -> any Transport
    ) async throws -> Client {
        if let existing = self.sessions[key] {
            return existing.client
        }
        let client = Client(name: key.clientName, version: key.clientVersion)
        _ = try await client.connect(transport: makeTransport())
        self.sessions[key] = Session(client: client)
        return client
    }

    private func evictExpired() {
        let cutoff = Date().addingTimeInterval(-Self.idleTimeout)
        let stale = self.sessions.filter { $0.value.lastUsed < cutoff }
        guard !stale.isEmpty else {
            return
        }
        for key in stale.keys {
            self.sessions.removeValue(forKey: key)
        }
        // Disconnect off the actor: teardown is I/O and nothing else
        // needs to wait for it.
        let clients = stale.values.map(\.client)
        Task {
            for client in clients {
                await client.disconnect()
            }
        }
    }
}
