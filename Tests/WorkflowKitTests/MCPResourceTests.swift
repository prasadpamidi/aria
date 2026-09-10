import Foundation
import MCP
@testable import WorkflowKit
import XCTest

// MARK: - MCPResourceTests

final class MCPResourceTests: XCTestCase {
    // MARK: - isInteractiveUI

    /// MCP Apps are identified by *both* a `ui://` URI and the
    /// `profile=mcp-app` MIME parameter. Treating plain `text/html` as
    /// an app would hand a message channel to a server that only meant
    /// to serve a document.
    func testInteractiveUIRequiresBothURISchemeAndProfile() {
        XCTAssertTrue(Self.resource("ui://x", "text/html;profile=mcp-app").isInteractiveUI)
        XCTAssertTrue(Self.resource("ui://x", "text/html; profile=mcp-app").isInteractiveUI)
        XCTAssertFalse(Self.resource("ui://x", "text/html").isInteractiveUI)
        XCTAssertFalse(Self.resource("https://x", "text/html;profile=mcp-app").isInteractiveUI)
        XCTAssertFalse(Self.resource("ui://x", nil).isInteractiveUI)
    }

    // MARK: - Against the fake server

    func testListResourcesDrainsPagination() async throws {
        let resources = try await Self.withFakeServer { client in
            try await client.listResources()
        }
        XCTAssertEqual(resources.count, 2, "second page was dropped")
        XCTAssertTrue(resources.contains { $0.isInteractiveUI })
        XCTAssertTrue(resources.contains { $0.uri == "file://data.csv" })
    }

    func testReadResourceReturnsMarkup() async throws {
        let result = try await Self.withFakeServer { client in
            try await client.readResource(uri: "ui://dashboard")
        }
        XCTAssertEqual(result.firstHTMLResource?.text, "<h1>hi</h1>")
    }

    func testListPromptsCarriesArguments() async throws {
        let prompts = try await Self.withFakeServer { client in
            try await client.listPrompts()
        }
        XCTAssertEqual(prompts.first?.name, "summarise")
        XCTAssertEqual(prompts.first?.arguments.first?.name, "uri")
        XCTAssertEqual(prompts.first?.arguments.first?.required, true)
    }

    // MARK: Private

    private static func resource(_ uri: String, _ mime: String?) -> MCPResourceDescriptor {
        MCPResourceDescriptor(uri: uri, name: "n", mimeType: mime)
    }

    /// A real `MCPClient` wired to the in-process fake, so the
    /// mapping under test is the shipping code path.
    private static func withFakeServer<T: Sendable>(
        _ body: @Sendable (MCPClient) async throws -> T
    ) async throws -> T {
        let counter = FakeMCPTransport.ConnectCounter()
        let client = MCPClient(
            serverURL: URL(string: "https://example.test/mcp")!,
            credential: nil,
            clientName: "test-\(UUID().uuidString)",
            clientVersion: "1.0",
            transportFactory: { FakeMCPTransport(counter: counter) }
        )
        return try await body(client)
    }
}
