#if ARIA_MLX
    import Aria
    import Foundation

    // MARK: - QwenToolCallStreamParser

    /// Streaming parser for the Qwen family's Hermes-style tool-call
    /// output format. Qwen 2.5 / 3.x / 3.5 chat templates wrap tool
    /// calls in:
    ///
    /// ```
    /// <tool_call>
    /// {"name": "tool_name", "arguments": {...}}
    /// </tool_call>
    /// ```
    ///
    /// `mlx-swift-lm`'s built-in `.json` `ToolCallProcessor`
    /// technically targets this format, but in practice the Qwen 3.5
    /// jinja template has edge cases (newline placement, optional
    /// whitespace, escaped braces in nested args) that cause the
    /// built-in parser to miss tool calls — the raw `<tool_call>`
    /// tokens then leak as visible text. AriaMLX loads Qwen models
    /// with `toolCallFormat: nil` and routes raw `.chunk` text
    /// through this parser, mirroring how
    /// `Gemma4ToolCallStreamParser` and `Llama3ToolCallStreamParser`
    /// handle their respective family-specific envelopes.
    ///
    /// Two-state machine, JSON interior. Handles split markers across
    /// chunk boundaries by holding back a small suffix of the buffer.
    struct QwenToolCallStreamParser {
        // MARK: Internal

        enum Event {
            case textDelta(String)
            case toolCall(Aria.ToolCall)
        }

        /// Feed one raw text chunk from the generation stream.
        /// Returns whatever was decodable from the buffer so far —
        /// text deltas + completed tool calls.
        mutating func process(_ chunk: String) -> [Event] {
            self.buffer.append(chunk)
            var events: [Event] = []
            while !self.buffer.isEmpty {
                if self.insideToolCall {
                    guard let endRange = self.buffer.range(of: Self.endMarker) else {
                        // Wait for more data to complete the block.
                        break
                    }
                    let interior = String(self.buffer[..<endRange.lowerBound])
                    self.buffer.removeSubrange(
                        self.buffer.startIndex..<endRange.upperBound
                    )
                    self.insideToolCall = false
                    if let call = Self.parseInterior(interior) {
                        events.append(.toolCall(call))
                    }
                } else {
                    if let startRange = self.buffer.range(of: Self.startMarker) {
                        let before = String(self.buffer[..<startRange.lowerBound])
                        if !before.isEmpty {
                            events.append(.textDelta(before))
                        }
                        self.buffer.removeSubrange(
                            self.buffer.startIndex..<startRange.upperBound
                        )
                        self.insideToolCall = true
                    } else {
                        // Hold back the trailing N-1 chars — the
                        // next chunk might complete a `<tool_call>`
                        // marker split across the boundary.
                        let holdback = Self.startMarker.count - 1
                        let safeCount = max(0, self.buffer.count - holdback)
                        if safeCount > 0 {
                            let safeText = String(self.buffer.prefix(safeCount))
                            self.buffer.removeFirst(safeCount)
                            events.append(.textDelta(safeText))
                        }
                        break
                    }
                }
            }
            return events
        }

        /// Drain anything left in the buffer when the stream
        /// terminates. Partial tool calls are dropped rather than
        /// echoed as text — better to lose an incomplete call than
        /// surface half a JSON body in the bubble.
        mutating func flush() -> [Event] {
            var events: [Event] = []
            if self.insideToolCall {
                self.buffer = ""
                self.insideToolCall = false
            } else if !self.buffer.isEmpty {
                events.append(.textDelta(self.buffer))
                self.buffer = ""
            }
            return events
        }

        // MARK: Private

        private static let startMarker = "<tool_call>"
        private static let endMarker = "</tool_call>"

        private var buffer = ""
        private var insideToolCall = false

        // MARK: Interior parser

        /// Decode the JSON body of a `<tool_call>…</tool_call>`
        /// block into an `Aria.ToolCall`. Accepts both
        /// `{"name": …, "arguments": …}` (Hermes standard) and
        /// `{"name": …, "parameters": …}` (some fine-tunes use this
        /// alternative key).
        ///
        /// Returns `nil` for any interior that isn't a well-formed
        /// JSON object with at least a `name` field; the parser
        /// silently drops it rather than echoing as text.
        private static func parseInterior(_ interior: String) -> Aria.ToolCall? {
            let trimmed = interior.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }
            guard let data = trimmed.data(using: .utf8) else {
                return nil
            }
            guard let raw = try? JSONSerialization.jsonObject(with: data),
                  let dict = raw as? [String: Any] else {
                return nil
            }
            guard let name = (dict["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty else {
                return nil
            }
            let argsAny = dict["arguments"] ?? dict["parameters"] ?? [:]
            let arguments = Self.jsonValue(from: argsAny)
            return Aria.ToolCall(
                id: UUID().uuidString,
                name: name,
                arguments: arguments
            )
        }

        /// Recursively convert a `JSONSerialization` value into
        /// Aria's `JSONValue`. Same shape as `Llama3ToolCallStreamParser`
        /// — extracted to a parser-local helper to keep the two
        /// independent (and avoid an awkward shared-helpers file).
        private static func jsonValue(from any: Any) -> Aria.JSONValue {
            if let string = any as? String {
                return .string(string)
            }
            if let bool = any as? Bool {
                return .bool(bool)
            }
            if let int = any as? Int64 {
                return .integer(int)
            }
            if let int = any as? Int {
                return .integer(Int64(int))
            }
            if let number = any as? NSNumber {
                let isFloat = CFNumberIsFloatType(number)
                return isFloat
                    ? .number(number.doubleValue)
                    : .integer(number.int64Value)
            }
            if let dict = any as? [String: Any] {
                var out: [String: Aria.JSONValue] = [:]
                for (key, value) in dict {
                    out[key] = Self.jsonValue(from: value)
                }
                return .object(out)
            }
            if let array = any as? [Any] {
                return .array(array.map(Self.jsonValue(from:)))
            }
            return .null
        }
    }
#endif
