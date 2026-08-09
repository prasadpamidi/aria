import Foundation
import Logging
import MCP
@testable import WorkflowKit
import XCTest

// MARK: - FakeMCPTransport

/// An in-process MCP server, just complete enough to complete a
/// handshake and answer `tools/list`.
///
/// Worth the ~80 lines: the pool's whole job is deciding *when* to
/// connect, and that is invisible against a live server and untestable
/// against none. Every connect is counted here, which is the assertion
/// the pool actually needs.
actor FakeMCPTransport: Transport {
    // MARK: Lifecycle

    init(counter: ConnectCounter, failSend: Bool = false) {
        self.counter = counter
        self.failSend = failSend
    }

    // MARK: Internal

    /// Shared across the transports one factory produces, so a retry's
    /// fresh transport still reports into the same tally.
    final class ConnectCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.value
        }

        func increment() {
            self.lock.lock()
            self.value += 1
            self.lock.unlock()
        }
    }

    nonisolated var logger: Logger { Logger(label: "fake") }

    func connect() async throws {
        self.counter.increment()
    }

    func disconnect() async {
        self.continuation?.finish()
        self.continuation = nil
    }

    func send(_ data: Data) async throws {
        if self.failSend {
            throw MCP.MCPError.connectionClosed
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let method = object["method"] as? String
        else {
            return
        }
        // Notifications carry no id and expect no reply.
        guard let id = object["id"] else {
            return
        }
        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": "2025-06-18",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "fake", "version": "1.0"],
            ]
        case "tools/list":
            result = ["tools": [[
                "name": "echo",
                "description": "Echo input.",
                "inputSchema": ["type": "object"] as [String: Any],
            ]]]
        default:
            result = [:]
        }
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        guard let encoded = try? JSONSerialization.data(withJSONObject: response) else {
            return
        }
        self.continuation?.yield(encoded)
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    // MARK: Private

    private let counter: ConnectCounter
    private let failSend: Bool
    private var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation?
}

// MARK: - MCPSessionPoolTests

final class MCPSessionPoolTests: XCTestCase {
    /// The point of the whole change: two calls, one handshake.
    ///
    /// Before pooling, every call connected and disconnected — so a
    /// turn invoking three tools ran three `initialize` handshakes and
    /// presented itself to the server as three separate sessions.
    func testReusesOneSessionAcrossCalls() async throws {
        let counter = FakeMCPTransport.ConnectCounter()
        let pool = MCPSessionPool()
        let key = Self.key()

        for _ in 0 ..< 3 {
            _ = try await pool.withClient(
                key: key,
                makeTransport: { FakeMCPTransport(counter: counter) },
                body: { client in try await client.listTools(cursor: nil).0.count }
            )
        }
        XCTAssertEqual(counter.count, 1, "expected one handshake for three calls")
        await pool.closeAll()
    }

    /// A refreshed OAuth token bakes a new `Authorization` header into
    /// a new transport, so it must not ride the old session.
    func testDifferentCredentialGetsItsOwnSession() async throws {
        let counter = FakeMCPTransport.ConnectCounter()
        let pool = MCPSessionPool()

        for fingerprint in [1, 2] {
            _ = try await pool.withClient(
                key: Self.key(fingerprint: fingerprint),
                makeTransport: { FakeMCPTransport(counter: counter) },
                body: { client in try await client.listTools(cursor: nil).0.count }
            )
        }
        XCTAssertEqual(counter.count, 2)
        await pool.closeAll()
    }

    /// A pooled connection can die between calls. The caller cannot
    /// tell that from a bad request, so the pool absorbs it once.
    func testRetriesOnceOnConnectionFailure() async throws {
        let counter = FakeMCPTransport.ConnectCounter()
        let pool = MCPSessionPool()
        let attempts = FakeMCPTransport.ConnectCounter()

        let value: Int = try await pool.withClient(
            key: Self.key(),
            makeTransport: { FakeMCPTransport(counter: counter) },
            body: { client in
                attempts.increment()
                if attempts.count == 1 {
                    throw MCP.MCPError.connectionClosed
                }
                return try await client.listTools(cursor: nil).0.count
            }
        )
        XCTAssertEqual(value, 1)
        XCTAssertEqual(attempts.count, 2, "should have retried exactly once")
        XCTAssertEqual(counter.count, 2, "retry needs a fresh transport")
        await pool.closeAll()
    }

    /// A server error is the server *answering*. Retrying it would
    /// risk performing a non-idempotent action twice.
    func testDoesNotRetryServerErrors() async throws {
        let counter = FakeMCPTransport.ConnectCounter()
        let pool = MCPSessionPool()
        let attempts = FakeMCPTransport.ConnectCounter()

        do {
            _ = try await pool.withClient(
                key: Self.key(),
                makeTransport: { FakeMCPTransport(counter: counter) },
                body: { _ -> Int in
                    attempts.increment()
                    throw MCP.MCPError.serverError(code: -32000, message: "nope")
                }
            )
            XCTFail("expected the server error to propagate")
        } catch {
            XCTAssertEqual(attempts.count, 1, "server errors must not be retried")
        }
        await pool.closeAll()
    }

    // MARK: Private

    private static func key(fingerprint: Int = 0) -> MCPSessionKey {
        MCPSessionKey(
            endpoint: URL(string: "https://example.test/mcp")!,
            credentialFingerprint: fingerprint,
            clientName: "test",
            clientVersion: "1.0"
        )
    }
}
