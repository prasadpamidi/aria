#if ARIA_MLX
    #if canImport(MLXLMCommon)
        import Aria
        import XCTest
        @testable import AriaMLX

        /// LFM2 emits a *list* of calls inside one tag pair, which the
        /// library's `ToolCallParser` cannot represent — `parse`
        /// returns a single optional `ToolCall`. Handed two calls its
        /// regex produces one corrupt call rather than dropping the
        /// second, which is why Aria owns this format.
        final class LFM2ToolCallStreamParserTests: XCTestCase {
            // MARK: - The case the library gets wrong

            func testTwoCallsInOneBlockBothParse() {
                var parser = LFM2ToolCallStreamParser()
                let events = parser.process(
                    #"<|tool_call_start|>[get_weather(city="Paris"), current_time()]<|tool_call_end|>"#
                )
                let calls = Self.calls(in: events)

                XCTAssertEqual(calls.map(\.name), ["get_weather", "current_time"])
                XCTAssertEqual(calls.first?.arguments, .object(["city": .string("Paris")]))
                XCTAssertEqual(calls.last?.arguments, .object([:]))
            }

            /// A comma inside a value is not a separator — the only
            /// thing distinguishing them is depth.
            func testCommaInsideAStringValueDoesNotSplitTheCall() {
                var parser = LFM2ToolCallStreamParser()
                let events = parser.process(
                    #"<|tool_call_start|>[get_weather(city="Paris, France")]<|tool_call_end|>"#
                )
                let calls = Self.calls(in: events)

                XCTAssertEqual(calls.count, 1)
                XCTAssertEqual(calls.first?.arguments, .object(["city": .string("Paris, France")]))
            }

            // MARK: - Single calls

            func testSingleCallWithNoArguments() {
                var parser = LFM2ToolCallStreamParser()
                let events = parser.process("<|tool_call_start|>[current_time()]<|tool_call_end|>")
                XCTAssertEqual(Self.calls(in: events).map(\.name), ["current_time"])
            }

            func testArgumentTypesAreCoerced() {
                var parser = LFM2ToolCallStreamParser()
                let events = parser.process(
                    #"<|tool_call_start|>[f(a=1, b=2.5, c=true, d="x", e=None)]<|tool_call_end|>"#
                )
                XCTAssertEqual(
                    Self.calls(in: events).first?.arguments,
                    .object([
                        "a": .integer(1),
                        "b": .number(2.5),
                        "c": .bool(true),
                        "d": .string("x"),
                        "e": .null,
                    ])
                )
            }

            // MARK: - Streaming

            /// Calls arrive split across chunks as a matter of course.
            func testCallSplitAcrossChunks() {
                var parser = LFM2ToolCallStreamParser()
                var events = parser.process("<|tool_call_")
                events += parser.process(#"start|>[get_weather(city="Par"#)
                events += parser.process(#"is")]<|tool_call_end|>"#)

                let calls = Self.calls(in: events)
                XCTAssertEqual(calls.map(\.name), ["get_weather"])
                XCTAssertEqual(calls.first?.arguments, .object(["city": .string("Paris")]))
            }

            /// A partial opening tag must never reach the bubble as
            /// text — leaking control tokens is the failure this
            /// parser exists to prevent.
            func testPartialOpeningTagIsNotEmittedAsText() {
                var parser = LFM2ToolCallStreamParser()
                let events = parser.process("Here you go <|tool_")
                XCTAssertEqual(Self.text(in: events), "Here you go ")
            }

            func testPlainTextPassesThrough() {
                var parser = LFM2ToolCallStreamParser()
                let events = parser.process("Just an answer.")
                XCTAssertEqual(Self.text(in: events), "Just an answer.")
                XCTAssertTrue(Self.calls(in: events).isEmpty)
            }

            func testTextAroundACallIsPreserved() {
                var parser = LFM2ToolCallStreamParser()
                var events = parser.process("Checking. <|tool_call_start|>[current_time()]<|tool_call_end|> Done.")
                events += parser.flush()

                XCTAssertEqual(Self.text(in: events), "Checking.  Done.")
                XCTAssertEqual(Self.calls(in: events).map(\.name), ["current_time"])
            }

            /// Half a tool call is not text the user should read, and
            /// completing it would invent arguments.
            func testUnterminatedCallIsDiscardedOnFlush() {
                var parser = LFM2ToolCallStreamParser()
                _ = parser.process("<|tool_call_start|>[get_weather(city=")
                let flushed = parser.flush()

                XCTAssertTrue(Self.text(in: flushed).isEmpty)
                XCTAssertTrue(Self.calls(in: flushed).isEmpty)
            }

            // MARK: - Helpers

            private static func calls(in events: [LFM2ToolCallStreamParser.Event]) -> [Aria.ToolCall] {
                events.compactMap { event in
                    if case let .toolCall(call) = event { call } else { nil }
                }
            }

            private static func text(in events: [LFM2ToolCallStreamParser.Event]) -> String {
                events.compactMap { event in
                    if case let .textDelta(text) = event { text } else { nil }
                }.joined()
            }
        }
    #endif
#endif
