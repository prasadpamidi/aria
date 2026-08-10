@testable import Aria
import XCTest

/// Images were invisible to the context layer in two different ways,
/// and together they meant an attached photo either overflowed the
/// window or arrived with no tools at all.
final class ImageContextTests: XCTestCase {
    // MARK: - Cost

    /// An image counted at zero is invisible to every budget decision
    /// downstream: history windowing never drops it because it looks
    /// free, and the request overflows with the budget satisfied.
    func testAnImageCostsSomething() {
        let counter = HeuristicTokenCounter()
        let withImage = Message(role: .user, content: [
            .text("what is this?"),
            .image(ImageContent(source: .data(Data(repeating: 0, count: 64), mimeType: "image/jpeg"))),
        ])
        let withoutImage = Message(role: .user, content: [.text("what is this?")])

        XCTAssertGreaterThan(
            counter.count(message: withImage),
            counter.count(message: withoutImage) + 500,
            "an image priced at nearly nothing will never be windowed out"
        )
    }

    /// Two images cost more than one. Sounds trivial; a per-message
    /// constant would pass the test above and fail this one.
    func testImagesAreCountedIndividually() {
        let counter = HeuristicTokenCounter()
        let image = ContentPart.image(
            ImageContent(source: .data(Data(repeating: 0, count: 64), mimeType: "image/jpeg"))
        )
        let one = Message(role: .user, content: [image])
        let two = Message(role: .user, content: [image, image])
        XCTAssertGreaterThan(counter.count(message: two), counter.count(message: one))
    }

    // MARK: - Selection

    /// A photo with no caption gives the ranker nothing to rank on.
    /// That is not "nothing matched" — the ranker was never given a
    /// question — and treating it as a decision sent zero tools.
    func testImageOnlyTurnStillGetsTools() async {
        // More tools than `maxTools`, or the assembler short-circuits
        // and returns everything unranked — which passes this test
        // without ever reaching the code it is about.
        let tools = (0 ..< 12).map { index in
            AnyTool(
                definition: ToolDefinition(
                    name: "tool_\(index)",
                    description: "Does a thing.",
                    inputSchema: .object(properties: [:], required: [])
                ),
                invoke: { _, _ in .object([:]) }
            )
        }
        var state = AgentState()
        state.messages = [Message(role: .user, content: [
            .image(ImageContent(source: .data(Data(repeating: 0, count: 64), mimeType: "image/jpeg"))),
        ])]

        let assembled = await DefaultContextAssembler(unrankedFillLimit: 0).assemble(
            systemPrompt: "You are helpful.",
            tools: tools,
            state: state,
            budget: ContextBudget(total: 8192, reservedForOutput: 768, maxTools: 6)
        )
        XCTAssertFalse(
            assembled.tools.isEmpty,
            "an uncaptioned image arrived with no way to act on it"
        )
    }

    /// A captioned image still ranks on its caption — the fallback must
    /// not swallow the normal path.
    func testCaptionedImageStillRanksOnItsText() async {
        let weather = AnyTool(
            definition: ToolDefinition(
                name: "get_weather",
                description: "Get the weather forecast for a location.",
                inputSchema: .object(properties: [:], required: [])
            ),
            invoke: { _, _ in .object([:]) }
        )
        // Enough tools that ranking actually runs: under `maxTools`
        // with room to spare, the assembler returns everything
        // unranked, and this would be testing the early exit.
        let filler = (0 ..< 10).map { index in
            AnyTool(
                definition: ToolDefinition(
                    name: "unrelated_tool_\(index)",
                    description: "Encode or decode base64 payloads.",
                    inputSchema: .object(properties: [:], required: [])
                ),
                invoke: { _, _ in .object([:]) }
            )
        }
        var state = AgentState()
        state.messages = [Message(role: .user, content: [
            .text("what is the weather here"),
            .image(ImageContent(source: .data(Data(repeating: 0, count: 64), mimeType: "image/jpeg"))),
        ])]

        let assembled = await DefaultContextAssembler(unrankedFillLimit: 0).assemble(
            systemPrompt: "You are helpful.",
            tools: filler + [weather],
            state: state,
            budget: ContextBudget(total: 8192, reservedForOutput: 768, maxTools: 6)
        )
        XCTAssertEqual(assembled.tools.first?.name, "get_weather")
    }
}
