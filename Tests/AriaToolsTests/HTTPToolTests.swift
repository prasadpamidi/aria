import Aria
import AriaTools
import Foundation
import XCTest

// MARK: - HTTPToolTests

final class HTTPToolTests: XCTestCase {
    // MARK: - Happy paths

    func testReturnsBodyAndStatusForTextResponse() async throws {
        let client = StubHTTPClient(
            status: 200,
            headers: ["Content-Type": "application/json"],
            data: Data(#"{"ok":true}"#.utf8)
        )
        let tool = HTTPTool(client: client)
        let output = try await tool.call(
            HTTPTool.Input(url: "https://example.com/api", method: nil, headers: nil, body: nil),
            context: ToolContext()
        )
        XCTAssertEqual(output.status, 200)
        XCTAssertEqual(output.body, #"{"ok":true}"#)
        XCTAssertEqual(output.headers["Content-Type"], "application/json")
        XCTAssertFalse(output.isBinary)
    }

    func testDefaultMethodIsGET() async throws {
        let client = StubHTTPClient(status: 200, data: Data())
        let tool = HTTPTool(client: client)
        _ = try await tool.call(
            HTTPTool.Input(url: "https://example.com", method: nil, headers: nil, body: nil),
            context: ToolContext()
        )
        XCTAssertEqual(client.lastRequest?.httpMethod, "GET")
    }

    func testCustomMethodIsForwarded() async throws {
        let client = StubHTTPClient(status: 201, data: Data())
        let tool = HTTPTool(client: client)
        _ = try await tool.call(
            HTTPTool.Input(url: "https://example.com", method: "post", headers: nil, body: "hi"),
            context: ToolContext()
        )
        XCTAssertEqual(client.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(client.lastRequest?.httpBody, Data("hi".utf8))
    }

    func testHeadersAreApplied() async throws {
        let client = StubHTTPClient(status: 200, data: Data())
        let tool = HTTPTool(client: client)
        _ = try await tool.call(
            HTTPTool.Input(
                url: "https://example.com",
                method: nil,
                headers: ["X-Test": "yes", "Authorization": "Bearer t"],
                body: nil
            ),
            context: ToolContext()
        )
        XCTAssertEqual(client.lastRequest?.value(forHTTPHeaderField: "X-Test"), "yes")
        XCTAssertEqual(client.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    // MARK: - Edge cases

    func testBinaryResponseSurfacesByteCountInsteadOfGarbage() async throws {
        // Non-UTF-8 bytes — the tool should refuse to make up a
        // string body and instead expose a `<binary: N bytes>`
        // placeholder so the model sees a useful signal.
        let bytes = Data([0xFF, 0xFE, 0xFD, 0xFC])
        let client = StubHTTPClient(status: 200, data: bytes)
        let tool = HTTPTool(client: client)
        let output = try await tool.call(
            HTTPTool.Input(url: "https://example.com/img.png", method: nil, headers: nil, body: nil),
            context: ToolContext()
        )
        XCTAssertTrue(output.isBinary)
        XCTAssertEqual(output.body, "<binary: 4 bytes>")
    }

    func testInvalidURLThrows() async {
        // Empty-string URL — `URL(string: "")` is consistently nil
        // across platforms. Foundation's `URL(string:)` is
        // surprisingly permissive about most other malformed inputs
        // on iOS, so any "this isn't really a URL" assertion has to
        // pick a form that actually fails parsing.
        let tool = HTTPTool(client: StubHTTPClient(status: 200, data: Data()))
        do {
            _ = try await tool.call(
                HTTPTool.Input(url: "", method: nil, headers: nil, body: nil),
                context: ToolContext()
            )
            XCTFail("expected throw")
        } catch let HTTPToolError.invalidURL(raw) {
            XCTAssertEqual(raw, "")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

// MARK: - StubHTTPClient

/// Captures the request and returns canned response bytes — lets us
/// assert on `URLRequest` shape without going through the network.
private final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    // MARK: Lifecycle

    init(status: Int, headers: [String: String] = [:], data: Data) {
        self.status = status
        self.headers = headers
        self.data = data
    }

    // MARK: Internal

    let status: Int
    let headers: [String: String]
    let data: Data

    /// `lastRequest` is read after the awaited call returns, so a
    /// nonisolated property without explicit locking is fine — tests
    /// don't fire `perform` from multiple tasks concurrently. Switched
    /// off `NSLock` because Swift 6 strict concurrency rejects
    /// `lock/unlock` from async contexts.
    private(set) var lastRequest: URLRequest?

    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        self.lastRequest = request
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "about:blank")!,
            statusCode: self.status,
            httpVersion: "HTTP/1.1",
            headerFields: self.headers
        )!
        return (self.data, response)
    }
}
