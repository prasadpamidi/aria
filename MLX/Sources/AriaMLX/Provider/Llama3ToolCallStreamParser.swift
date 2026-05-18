#if canImport(MLXLMCommon)
    import Aria
    import Foundation

    // MARK: - Llama3ToolCallStreamParser

    /// Streaming parser for the Llama 3.x family's tool-call output
    /// format. Llama 3 / 3.1 / 3.2 chat templates wrap tool calls in:
    ///
    /// ```
    /// <|python_tag|>{"name": "tool_name", "parameters": {...}}<|eom_id|>
    /// ```
    ///
    /// Some fine-tunes use `"arguments"` instead of `"parameters"`,
    /// or terminate with `<|eot_id|>` instead of `<|eom_id|>`. The
    /// parser accepts both keys and both terminators.
    ///
    /// `mlx-swift-lm`'s built-in `ToolCallProcessor` does not handle
    /// this envelope reliably — the `<|python_tag|>` prefix + JSON
    /// body leak through to the user-visible response on most builds.
    /// AriaMLX loads Llama models with `toolCallFormat: nil` (no
    /// upstream override) and pulls tool calls out of the raw
    /// `.chunk` stream here, exactly mirroring how
    /// `Gemma4ToolCallStreamParser` handles Gemma 4's custom format.
    ///
    /// The parser is a two-state machine. While outside a python tag
    /// it forwards text deltas, holding back a small suffix that
    /// could complete a `<|python_tag|>` marker split across two
    /// chunk boundaries. While inside, it accumulates until it sees
    /// the matching terminator, then JSON-decodes the body into an
    /// `Aria.ToolCall`.
    struct Llama3ToolCallStreamParser {
        // MARK: Internal

        enum Event {
            case textDelta(String)
            case toolCall(Aria.ToolCall)
        }

        /// Feed one raw text chunk from the generation stream.
        /// Returns whatever was decodable from the buffer state so
        /// far — text deltas + completed tool calls.
        mutating func process(_ chunk: String) -> [Event] {
            self.buffer.append(chunk)
            var events: [Event] = []
            while !self.buffer.isEmpty {
                if self.insidePythonTag {
                    // Wait for either terminator to appear, taking
                    // the earlier one if both eventually arrive in
                    // the same chunk.
                    let eomRange = self.buffer.range(of: Self.eomMarker)
                    let eotRange = self.buffer.range(of: Self.eotMarker)
                    let endRange = Self.earlier(eomRange, eotRange)
                    guard let endRange else {
                        // Wait for more data to complete the block.
                        break
                    }
                    let interior = String(self.buffer[..<endRange.lowerBound])
                    self.buffer.removeSubrange(
                        self.buffer.startIndex ..< endRange.upperBound
                    )
                    self.insidePythonTag = false
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
                            self.buffer.startIndex ..< startRange.upperBound
                        )
                        self.insidePythonTag = true
                    } else {
                        // Hold back the trailing N-1 chars — the
                        // next chunk might complete a `<|python_tag|>`
                        // marker that was split across the boundary.
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

        /// Drain whatever's left in the buffer when the stream
        /// terminates. Partial tool calls (start marker arrived but
        /// no terminator) are dropped — better to lose an incomplete
        /// call than echo half a JSON body as text.
        mutating func flush() -> [Event] {
            var events: [Event] = []
            if self.insidePythonTag {
                self.buffer = ""
                self.insidePythonTag = false
            } else if !self.buffer.isEmpty {
                events.append(.textDelta(self.buffer))
                self.buffer = ""
            }
            return events
        }

        // MARK: Private

        /// Llama 3 chat-template control tokens.
        private static let startMarker = "<|python_tag|>"
        private static let eomMarker = "<|eom_id|>"
        private static let eotMarker = "<|eot_id|>"

        private var buffer = ""
        private var insidePythonTag = false

        /// Return whichever range starts earlier in the source
        /// string; `nil` if both are nil. Lets the main loop pick
        /// the first terminator without ambiguity when both could
        /// arrive in the same chunk.
        private static func earlier(
            _ lhs: Range<String.Index>?,
            _ rhs: Range<String.Index>?
        ) -> Range<String.Index>? {
            switch (lhs, rhs) {
            case (nil, nil): nil
            case let (some?, nil): some
            case let (nil, some?): some
            case let (l?, r?): l.lowerBound < r.lowerBound ? l : r
            }
        }

        // MARK: Interior parser

        /// Decode the JSON body of a `<|python_tag|>…<|eom_id|>`
        /// block into an `Aria.ToolCall`. Accepts both
        /// `{"name": …, "parameters": …}` and
        /// `{"name": …, "arguments": …}` shapes — different Llama 3
        /// fine-tunes use one or the other.
        ///
        /// Returns `nil` for any interior that isn't a well-formed
        /// JSON object with at least a `name` field; the parser
        /// silently drops it rather than echoing as text.
        private static func parseInterior(_ interior: String) -> Aria.ToolCall? {
            let trimmed = interior.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let data = trimmed.data(using: .utf8) else { return nil }
            guard let raw = try? JSONSerialization.jsonObject(with: data),
                  let dict = raw as? [String: Any] else {
                return nil
            }
            guard let name = (dict["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty
            else { return nil }
            let argsAny = dict["parameters"] ?? dict["arguments"] ?? [:]
            let arguments = Self.jsonValue(from: argsAny)
            return Aria.ToolCall(
                id: UUID().uuidString,
                name: name,
                arguments: arguments
            )
        }

        /// Recursively convert a `JSONSerialization` value into
        /// Aria's `JSONValue`. Strings stay strings, numbers split
        /// into integer vs double, arrays and dicts recurse,
        /// everything else becomes `.null`.
        private static func jsonValue(from any: Any) -> Aria.JSONValue {
            if let string = any as? String {
                return .string(string)
            }
            if let bool = any as? Bool {
                return .bool(bool)
            }
            // Order matters: Bool is also Int in some bridging
            // paths, so the Bool check above must come first.
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
