#if canImport(MLXLMCommon)
    import XCTest
    @testable import Aria
    @testable import AriaMLX

    final class Gemma4ToolCallStreamParserTests: XCTestCase {
        // MARK: - Single-chunk happy path

        func testParsesSingleStringArgument() {
            var parser = Gemma4ToolCallStreamParser()
            let events = parser.process(
                #"<|tool_call>call:remember_fact{text:<|"|>my name is Prasad<|"|>}<tool_call|>"#
            )
            XCTAssertEqual(events.count, 1)
            guard case let .toolCall(call) = events[0] else {
                XCTFail("expected toolCall event, got \(events)")
                return
            }
            XCTAssertEqual(call.name, "remember_fact")
            XCTAssertEqual(call.arguments, .object(["text": .string("my name is Prasad")]))
        }

        func testParsesMixedArgumentTypes() {
            var parser = Gemma4ToolCallStreamParser()
            let events = parser.process(
                #"<|tool_call>call:set{name:<|"|>x<|"|>,count:42,enabled:true,ratio:1.5,nada:null}<tool_call|>"#
            )
            guard case let .toolCall(call) = events.last else {
                XCTFail("expected toolCall, got \(events)")
                return
            }
            XCTAssertEqual(call.name, "set")
            XCTAssertEqual(call.arguments, .object([
                "name": .string("x"),
                "count": .integer(42),
                "enabled": .bool(true),
                "ratio": .number(1.5),
                "nada": .null
            ]))
        }

        // MARK: - Streaming edge cases

        func testHandlesMarkerSplitAcrossChunks() {
            var parser = Gemma4ToolCallStreamParser()
            let chunks = [
                "Sure, calling tool: ",
                "<|tool",
                "_call>call:rem",
                "ember_fact{text:<|\"|>hi<|\"|>}<too",
                "l_call|> done."
            ]
            var collected: [Gemma4ToolCallStreamParser.Event] = []
            for chunk in chunks {
                collected.append(contentsOf: parser.process(chunk))
            }
            collected.append(contentsOf: parser.flush())

            let toolCalls = collected.compactMap { event -> Aria.ToolCall? in
                if case let .toolCall(call) = event { call } else { nil }
            }
            XCTAssertEqual(toolCalls.count, 1)
            XCTAssertEqual(toolCalls.first?.name, "remember_fact")
            XCTAssertEqual(toolCalls.first?.arguments, .object(["text": .string("hi")]))

            // Text that came before the marker and after the close
            // marker should be preserved as text deltas.
            let text = Self.joinedTextDeltas(collected)
            XCTAssertTrue(text.contains("Sure, calling tool:"), "got: \(text)")
            XCTAssertTrue(text.contains("done."), "got: \(text)")
        }

        func testTextOnlyChunksPassThroughWithoutHoldingTrailingChars() {
            var parser = Gemma4ToolCallStreamParser()
            let events = parser.process("Hello world. ")
            // Holds back N-1 = 11 chars (length of "<|tool_call>" - 1).
            // So the first ~14 chars get yielded, the trailing 11 stay buffered.
            let text = Self.joinedTextDeltas(events)
            XCTAssertFalse(text.isEmpty)
            XCTAssertTrue("Hello world. ".hasPrefix(text), "yielded \(text)")

            let final = Self.joinedTextDeltas(parser.flush())
            XCTAssertEqual(text + final, "Hello world. ")
        }

        // MARK: - Helpers

        private static func joinedTextDeltas(
            _ events: [Gemma4ToolCallStreamParser.Event]
        ) -> String {
            let parts = events.compactMap { event -> String? in
                if case let .textDelta(text) = event { text } else { nil }
            }
            return parts.joined()
        }

        func testIncompleteToolCallAtEndOfStreamIsDropped() {
            var parser = Gemma4ToolCallStreamParser()
            _ = parser.process("<|tool_call>call:foo{ text:<|\"|>incomplete")
            let trailing = parser.flush()
            // No tool call should be emitted; partial buffer is dropped.
            XCTAssertTrue(trailing.allSatisfy { event in
                if case .toolCall = event {
                    false
                } else {
                    true
                }
            })
        }

        // MARK: - Malformed input

        func testReturnsNoToolCallWhenInteriorMissingCallPrefix() {
            var parser = Gemma4ToolCallStreamParser()
            let events = parser.process("<|tool_call>not_a_call_format<tool_call|>")
            let calls = events.compactMap { event -> Aria.ToolCall? in
                if case let .toolCall(call) = event { call } else { nil }
            }
            XCTAssertTrue(calls.isEmpty)
        }

        func testTwoToolCallsInSameStream() {
            var parser = Gemma4ToolCallStreamParser()
            let events = parser.process(
                #"<|tool_call>call:a{x:1}<tool_call|> and <|tool_call>call:b{y:2}<tool_call|>"#
            )
            let calls = events.compactMap { event -> Aria.ToolCall? in
                if case let .toolCall(call) = event { call } else { nil }
            }
            XCTAssertEqual(calls.map(\.name), ["a", "b"])
        }
    }
#endif
