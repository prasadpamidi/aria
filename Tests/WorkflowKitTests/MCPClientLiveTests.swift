import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - MCPClientLiveTests

/// End-to-end coverage for `MCPClient` against a *real* MCP server.
/// Disabled unless `MCP_LIVE_URL` is set, so `swift test` stays
/// hermetic in CI. Point it at a Streamable HTTP server to verify the
/// SDK-backed client against both JSON and SSE responses:
///
/// ```sh
/// MCP_LIVE_URL=http://localhost:3939/mcp \
///   swift test --filter MCPClientLiveTests
/// ```
///
/// The assertions assume the bundled `simplemcp` reference server
/// (a `get_weather` tool returning text + an embedded HTML card).
/// Override the tool/argument via `MCP_LIVE_TOOL` / `MCP_LIVE_CITY`.
struct MCPClientLiveTests {
    static var liveURL: URL? {
        guard let raw = ProcessInfo.processInfo.environment["MCP_LIVE_URL"] else {
            return nil
        }
        return URL(string: raw)
    }

    private static var toolName: String {
        ProcessInfo.processInfo.environment["MCP_LIVE_TOOL"] ?? "get_weather"
    }

    private static var city: String {
        ProcessInfo.processInfo.environment["MCP_LIVE_CITY"] ?? "Tokyo"
    }

    @Test(.enabled(if: MCPClientLiveTests.liveURL != nil))
    func listToolsDiscoversAtLeastOneTool() async throws {
        let client = MCPClient(serverURL: Self.liveURL!)
        let tools = try await client.listTools()
        #expect(!tools.isEmpty)
        #expect(tools.contains { $0.name == Self.toolName })
    }

    @Test(.enabled(if: MCPClientLiveTests.liveURL != nil))
    func callToolReturnsText() async throws {
        let client = MCPClient(serverURL: Self.liveURL!)
        let text = try await client.callTool(
            name: Self.toolName,
            arguments: ["city": .string(Self.city)]
        )
        #expect(!text.isEmpty)
    }

    @Test(.enabled(if: MCPClientLiveTests.liveURL != nil))
    func callToolDetailedSurfacesEmbeddedHTMLResource() async throws {
        let client = MCPClient(serverURL: Self.liveURL!)
        let result = try await client.callToolDetailed(
            name: Self.toolName,
            arguments: ["city": .string(Self.city)]
        )
        #expect(!result.isError)
        // The whole point: the post-call UI resource (HTML) is reachable.
        let html = result.firstHTMLResource
        #expect(html != nil)
        #expect(html?.text?.isEmpty == false)
    }
}
