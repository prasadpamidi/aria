import Foundation
import XCTest
@testable import Aria

final class MessageTests: XCTestCase {
    func testConvenienceConstructors() {
        let user = Message.user("hi")
        XCTAssertEqual(user.role, .user)
        XCTAssertEqual(user.textContent, "hi")
        XCTAssertTrue(user.toolCalls.isEmpty)

        let system = Message.system("you are a bot")
        XCTAssertEqual(system.role, .system)
        XCTAssertEqual(system.textContent, "you are a bot")

        let assistant = Message.assistant("hello")
        XCTAssertEqual(assistant.role, .assistant)

        let tool = Message.tool(callId: "t1", text: "result")
        XCTAssertEqual(tool.role, .tool)
        XCTAssertEqual(tool.toolCallId, "t1")
        XCTAssertEqual(tool.textContent, "result")
    }

    func testUserWithImagesAttachesImageContentParts() throws {
        let imageData = Data([0x01, 0x02, 0x03])
        let image = ImageContent(source: .data(imageData, mimeType: "image/jpeg"))
        let message = Message.user("describe this", images: [image])
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content.count, 2)
        // Text part still composes via textContent so text-only
        // providers see only the prompt.
        XCTAssertEqual(message.textContent, "describe this")
        guard case let .image(attached) = message.content.last else {
            XCTFail("Expected trailing image content part")
            return
        }
        guard case let .data(roundTrip, mimeType) = attached.source else {
            XCTFail("Expected image source to round-trip as .data")
            return
        }
        XCTAssertEqual(roundTrip, imageData)
        XCTAssertEqual(mimeType, "image/jpeg")
    }

    func testTextContentConcatenatesTextPartsOnly() {
        let message = Message(
            role: .assistant,
            content: [
                .text("Hello "),
                .image(ImageContent(source: .identifier("xyz"))),
                .text("world")
            ]
        )
        XCTAssertEqual(message.textContent, "Hello world")
    }

    func testCodableRoundTrip() throws {
        let original = Message(
            role: .assistant,
            content: [.text("hello"), .toolUse(ToolCall(id: "t1", name: "x", arguments: .null))],
            toolCalls: [ToolCall(id: "t1", name: "x", arguments: .null)],
            metadata: ["latency_ms": .integer(120)]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let roundTrip = try JSONDecoder().decode(Message.self, from: data)

        XCTAssertEqual(roundTrip.role, original.role)
        XCTAssertEqual(roundTrip.content, original.content)
        XCTAssertEqual(roundTrip.toolCalls, original.toolCalls)
        XCTAssertEqual(roundTrip.metadata, original.metadata)
    }

    func testContentPartCodableForEachKind() throws {
        let parts: [ContentPart] = try [
            .text("hi"),
            .image(ImageContent(source: .url(XCTUnwrap(URL(string: "https://example.com/img"))), detail: .high)),
            .audio(AudioContent(source: .identifier("a1"), duration: 5.0)),
            .toolUse(ToolCall(id: "t1", name: "n", arguments: .object(["x": .integer(1)]))),
            .toolResult(id: "t1", content: [.text("ok")], isError: false)
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(parts)
        let decoded = try JSONDecoder().decode([ContentPart].self, from: data)
        XCTAssertEqual(decoded, parts)
    }
}
