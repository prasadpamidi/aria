#if canImport(MLXLMCommon)
    import Aria
    import Foundation

    // MARK: - Gemma4ToolCallStreamParser

    /// Streaming parser for Gemma 4's tool-call output format. The
    /// chat template emits:
    ///
    /// ```
    /// <|tool_call>call:NAME{
    ///     key1:<|"|>string value<|"|>,
    ///     key2:42
    /// }<tool_call|>
    /// ```
    ///
    /// `mlx-swift-lm`'s built-in `ToolCallProcessor` doesn't recognise
    /// either the `<|tool_call>` / `<tool_call|>` delimiters or the
    /// `call:NAME{...}` interior — every existing
    /// `ToolCallParser` (`.gemma`, `.json`, `.glm4`, …) targets a
    /// different shape. Until upstream adds Gemma 4 support, AriaMLX
    /// loads Gemma 4 with `toolCallFormat: nil` and pulls tool calls
    /// back out of the raw `.chunk` stream here.
    ///
    /// The parser is a small two-state machine over text chunks. It
    /// holds back any trailing prefix that could be the start of a
    /// `<|tool_call>` marker so partial markers split across chunk
    /// boundaries don't leak into the user-visible text. Strings in
    /// argument values are wrapped by the `<|"|>` escape marker and
    /// non-string values (numbers, booleans, null) are bare; both are
    /// surfaced as the matching `Aria.JSONValue`.
    struct Gemma4ToolCallStreamParser {
        // MARK: Internal

        enum Event {
            case textDelta(String)
            case toolCall(Aria.ToolCall)
        }

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
                    self.buffer.removeSubrange(self.buffer.startIndex..<endRange.upperBound)
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
                        self.buffer.removeSubrange(self.buffer.startIndex..<startRange.upperBound)
                        self.insideToolCall = true
                    } else {
                        // Hold back the trailing N-1 chars — the next
                        // chunk might complete a `<|tool_call>` marker.
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

        mutating func flush() -> [Event] {
            var events: [Event] = []
            if self.insideToolCall {
                // Incomplete tool call at end of stream — drop the
                // partial buffer rather than try to parse half a call.
                self.buffer = ""
                self.insideToolCall = false
            } else if !self.buffer.isEmpty {
                events.append(.textDelta(self.buffer))
                self.buffer = ""
            }
            return events
        }

        // MARK: Private

        private static let startMarker = "<|tool_call>"
        private static let endMarker = "<tool_call|>"
        private static let stringEscape = "<|\"|>"

        private var buffer = ""
        private var insideToolCall = false

        // MARK: Interior parser

        private static func parseInterior(_ interior: String) -> Aria.ToolCall? {
            var trimmed = interior.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("call:") else {
                return nil
            }
            trimmed.removeFirst("call:".count)
            guard let braceIdx = trimmed.firstIndex(of: "{") else {
                return nil
            }
            let name = String(trimmed[..<braceIdx])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                return nil
            }
            guard let closeIdx = Self.matchingClose(in: trimmed, openIdx: braceIdx) else {
                return nil
            }
            let argsStart = trimmed.index(after: braceIdx)
            let argsStr = String(trimmed[argsStart..<closeIdx])
            let arguments = Self.parseArgs(argsStr)
            return Aria.ToolCall(
                id: UUID().uuidString,
                name: name,
                arguments: .object(arguments)
            )
        }

        private static func matchingClose(
            in text: String,
            openIdx: String.Index
        ) -> String.Index? {
            var depth = 1
            var idx = text.index(after: openIdx)
            while idx < text.endIndex {
                switch text[idx] {
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return idx
                    }
                default: break
                }
                idx = text.index(after: idx)
            }
            return nil
        }

        private static func parseArgs(_ argsStr: String) -> [String: Aria.JSONValue] {
            var result: [String: Aria.JSONValue] = [:]
            for pair in Self.splitTopLevel(argsStr, by: ",") {
                let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let colonIdx = trimmed.firstIndex(of: ":") else {
                    continue
                }
                let key = String(trimmed[..<colonIdx])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else {
                    continue
                }
                let valueStr = String(trimmed[trimmed.index(after: colonIdx)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                result[key] = Self.parseValue(valueStr)
            }
            return result
        }

        private static func parseValue(_ raw: String) -> Aria.JSONValue {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix(Self.stringEscape),
               value.hasSuffix(Self.stringEscape),
               value.count >= 2 * Self.stringEscape.count {
                let start = value.index(value.startIndex, offsetBy: Self.stringEscape.count)
                let end = value.index(value.endIndex, offsetBy: -Self.stringEscape.count)
                return .string(String(value[start..<end]))
            }
            if value == "true" {
                return .bool(true)
            }
            if value == "false" {
                return .bool(false)
            }
            if value == "null" {
                return .null
            }
            if let int = Int64(value) {
                return .integer(int)
            }
            if let double = Double(value) {
                return .number(double)
            }
            return .string(value)
        }

        /// Split `s` on `delimiter` while respecting brace depth and
        /// `<|"|>`-quoted regions. Used to break the args body into
        /// `key:value` chunks even when string values contain commas.
        private static func splitTopLevel(_ source: String, by delimiter: Character) -> [String] {
            var result: [String] = []
            var current = ""
            var braceDepth = 0
            var inString = false
            var idx = source.startIndex
            while idx < source.endIndex {
                let remaining = source[idx...]
                if remaining.hasPrefix(Self.stringEscape) {
                    inString.toggle()
                    current.append(Self.stringEscape)
                    idx = source.index(idx, offsetBy: Self.stringEscape.count)
                    continue
                }
                let char = source[idx]
                if !inString {
                    if char == "{" {
                        braceDepth += 1
                    }
                    if char == "}" {
                        braceDepth -= 1
                    }
                    if char == delimiter, braceDepth == 0 {
                        result.append(current)
                        current = ""
                        idx = source.index(after: idx)
                        continue
                    }
                }
                current.append(char)
                idx = source.index(after: idx)
            }
            if !current.isEmpty {
                result.append(current)
            }
            return result
        }
    }
#endif
