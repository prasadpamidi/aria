import Foundation
import Testing
@testable import WorkflowKit

// MARK: - MCPContentTests

/// Unit coverage for the MCP content model — the layer that decides
/// what a caller can pull out of a `tools/call` reply. These pin the
/// behaviour the app relies on (concatenated text for the model, the
/// embedded HTML resource for the UI) without needing a live server;
/// end-to-end transport behaviour is exercised by `MCPClientLiveTests`.
struct MCPContentTests {
    private static func htmlResource() -> MCPResourceContent {
        MCPResourceContent(
            uri: "ui://weather/tokyo",
            mimeType: "text/html",
            text: "<div>72°F</div>",
            blob: nil
        )
    }

    @Test
    func textConcatenatesOnlyTextBlocks() {
        let result = MCPCallResult(
            content: [
                .text("Weather in Tokyo: "),
                .resource(Self.htmlResource()),
                .text("72°F"),
            ],
            isError: false
        )
        // The model-facing string ignores the resource block.
        #expect(result.text == "Weather in Tokyo: 72°F")
    }

    @Test
    func resourcesExtractsEmbeddedResources() {
        let result = MCPCallResult(
            content: [.text("summary"), .resource(Self.htmlResource())],
            isError: false
        )
        #expect(result.resources.count == 1)
        #expect(result.resources.first?.uri == "ui://weather/tokyo")
        #expect(result.resources.first?.text == "<div>72°F</div>")
    }

    @Test
    func firstHTMLResourcePicksHTMLByMIMEType() {
        let json = MCPResourceContent(
            uri: "data://x",
            mimeType: "application/json",
            text: "{}",
            blob: nil
        )
        let result = MCPCallResult(
            content: [.resource(json), .resource(Self.htmlResource())],
            isError: false
        )
        // Skips the JSON resource, returns the HTML one.
        #expect(result.firstHTMLResource?.uri == "ui://weather/tokyo")
    }

    @Test
    func firstHTMLResourceIsNilWhenNoHTML() {
        let result = MCPCallResult(
            content: [.text("just text")],
            isError: false
        )
        #expect(result.firstHTMLResource == nil)
        #expect(result.resources.isEmpty)
    }

    @Test
    func resourceIsHTMLIsCaseInsensitiveAndNilSafe() {
        #expect(MCPResourceContent(uri: "u", mimeType: "TEXT/HTML", text: nil, blob: nil).isHTML)
        #expect(MCPResourceContent(uri: "u", mimeType: "text/html; charset=utf-8", text: nil, blob: nil).isHTML)
        #expect(!MCPResourceContent(uri: "u", mimeType: nil, text: nil, blob: nil).isHTML)
        #expect(!MCPResourceContent(uri: "u", mimeType: "image/png", text: nil, blob: nil).isHTML)
    }

    @Test
    func unknownBlockIsPreservedNotDropped() {
        // A future/unsupported block must survive as `.unknown` so a
        // caller can at least observe that something arrived.
        let result = MCPCallResult(content: [.unknown(rawType: "video")], isError: false)
        #expect(result.text.isEmpty)
        #expect(result.resources.isEmpty)
        #expect(result.content.count == 1)
    }
}
