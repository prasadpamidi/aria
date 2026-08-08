#if ARIA_MLX
    import Aria
    import Foundation

    // MARK: - LFM2ToolCallStreamParser

    /// Streaming parser for LFM2 / LFM2.5 pythonic tool calls.
    ///
    /// The format wraps a *list* of calls in one tag pair, straight from
    /// the model's own chat template:
    ///
    /// ```jinja
    /// "<|tool_call_start|>[" + (tool_calls | join(", ")) + "]<|tool_call_end|>"
    /// ```
    ///
    /// producing, for two calls:
    ///
    /// ```text
    /// <|tool_call_start|>[get_weather(city="Paris"), current_time()]<|tool_call_end|>
    /// ```
    ///
    /// **Why not `mlx-swift-lm`'s `PythonicToolCallParser`.** Its
    /// `ToolCallParser.parse` returns a single optional `ToolCall`, so
    /// the interface cannot express more than one call per tag block —
    /// no change to its regex could fix that. Faced with the input
    /// above, its `\[(\w+)\((.*?)\)\]` pattern backtracks across the
    /// separator and yields `get_weather` with arguments
    /// `city="Paris"), current_time(`.
    ///
    /// That is worse than dropping the extra call: the *surviving* call
    /// is corrupt, so a turn that would have degraded to one action
    /// instead fails argument decoding entirely. A model already prone
    /// to shaky tool use then looks broken for a reason that is ours.
    ///
    /// Aria owns parsing for three model families already — Qwen,
    /// Gemma 4, Llama 3 — each because a built-in proved inadequate.
    /// This is the fourth, and the catalog entries pair it with
    /// `toolCallFormat: nil` so the library does not parse in parallel.
    struct LFM2ToolCallStreamParser {
        // MARK: Internal

        enum Event: Equatable {
            case textDelta(String)
            case toolCall(Aria.ToolCall)
        }

        /// Feed a streamed chunk; returns whatever became complete.
        ///
        /// Text outside the tags passes through immediately. Anything
        /// from an opening tag onward is buffered until its closing tag
        /// arrives, since a call split across chunk boundaries is the
        /// normal case rather than the exception.
        mutating func process(_ chunk: String) -> [Event] {
            self.buffer += chunk
            var events: [Event] = []

            while true {
                if self.insideCall {
                    guard let closeRange = buffer.range(of: Self.endTag) else {
                        return events
                    }
                    let interior = String(self.buffer[self.buffer.startIndex..<closeRange.lowerBound])
                    events.append(contentsOf: Self.parseCallList(interior).map(Event.toolCall))
                    self.buffer = String(self.buffer[closeRange.upperBound...])
                    self.insideCall = false
                    continue
                }

                guard let openRange = buffer.range(of: Self.startTag) else {
                    // Hold back a possible partial opening tag so it is
                    // never emitted as visible text.
                    let safe = Self.safeTextPrefixLength(of: self.buffer)
                    if safe > 0 {
                        let cut = self.buffer.index(self.buffer.startIndex, offsetBy: safe)
                        let text = String(self.buffer[self.buffer.startIndex..<cut])
                        if !text.isEmpty {
                            events.append(.textDelta(text))
                        }
                        self.buffer = String(self.buffer[cut...])
                    }
                    return events
                }

                let leading = String(self.buffer[self.buffer.startIndex..<openRange.lowerBound])
                if !leading.isEmpty {
                    events.append(.textDelta(leading))
                }
                self.buffer = String(self.buffer[openRange.upperBound...])
                self.insideCall = true
            }
        }

        /// Drain at end of stream.
        ///
        /// An unterminated call block is discarded rather than emitted:
        /// half a tool call is not text the user should read, and
        /// guessing at its completion would invent arguments.
        mutating func flush() -> [Event] {
            defer {
                self.buffer = ""
                self.insideCall = false
            }
            guard !self.insideCall else {
                return []
            }
            let remaining = self.buffer
            return remaining.isEmpty ? [] : [.textDelta(remaining)]
        }

        // MARK: Private

        private static let startTag = "<|tool_call_start|>"
        private static let endTag = "<|tool_call_end|>"

        private var buffer = ""
        private var insideCall = false

        /// Length of the prefix that cannot be the start of a tag.
        ///
        /// Streaming splits arbitrarily, so `<|tool_` may arrive alone.
        /// Emitting it as text would leak control tokens into the
        /// bubble — the leak this parser exists to prevent.
        private static func safeTextPrefixLength(of text: String) -> Int {
            let characters = Array(text)
            let tag = Array(Self.startTag)
            let maxOverlap = min(characters.count, tag.count - 1)
            var overlap = 0
            for length in stride(from: maxOverlap, through: 1, by: -1)
                where Array(characters.suffix(length)) == Array(tag.prefix(length)) {
                overlap = length
                break
            }
            return characters.count - overlap
        }

        /// Parse `[a(x=1), b()]` — or a bare `a(x=1)` — into calls.
        private static func parseCallList(_ interior: String) -> [Aria.ToolCall] {
            var body = interior.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasPrefix("["), body.hasSuffix("]") {
                body = String(body.dropFirst().dropLast())
            }
            // Split on separators outside parentheses and strings; a
            // comma inside `city="Paris, France"` is not a separator.
            return Self.splitTopLevel(body, by: ",")
                .compactMap { Self.parseCall($0) }
        }

        private static func parseCall(_ source: String) -> Aria.ToolCall? {
            let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let open = text.firstIndex(of: "("), text.hasSuffix(")") else {
                return nil
            }
            let name = String(text[text.startIndex..<open])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                return nil
            }
            let argsBody = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
            return Aria.ToolCall(
                id: UUID().uuidString,
                name: name,
                arguments: .object(Self.parseArgs(argsBody))
            )
        }

        private static func parseArgs(_ body: String) -> [String: Aria.JSONValue] {
            var arguments: [String: Aria.JSONValue] = [:]
            for pair in Self.splitTopLevel(body, by: ",") {
                let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let equals = trimmed.firstIndex(of: "=") else {
                    continue
                }
                let key = String(trimmed[trimmed.startIndex..<equals])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let raw = String(trimmed[trimmed.index(after: equals)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else {
                    continue
                }
                arguments[key] = Self.parseValue(raw)
            }
            return arguments
        }

        private static func parseValue(_ raw: String) -> Aria.JSONValue {
            if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
                return .string(String(raw.dropFirst().dropLast()))
            }
            if raw.hasPrefix("'"), raw.hasSuffix("'"), raw.count >= 2 {
                return .string(String(raw.dropFirst().dropLast()))
            }
            if raw == "True" || raw == "true" {
                return .bool(true)
            }
            if raw == "False" || raw == "false" {
                return .bool(false)
            }
            if raw == "None" || raw == "null" {
                return .null
            }
            if let integer = Int64(raw) {
                return .integer(integer)
            }
            if let number = Double(raw) {
                return .number(number)
            }
            return .string(raw)
        }

        /// Split on `delimiter` while respecting parentheses, brackets
        /// and quoted regions.
        ///
        /// The whole point of the parser: the separator between two
        /// calls looks identical to a comma inside an argument value,
        /// and only depth tracking tells them apart.
        private static func splitTopLevel(_ source: String, by delimiter: Character) -> [String] {
            var result: [String] = []
            var current = ""
            var depth = 0
            var quote: Character?

            for character in source {
                if let active = quote {
                    current.append(character)
                    if character == active {
                        quote = nil
                    }
                    continue
                }
                switch character {
                case "\"", "'":
                    quote = character
                    current.append(character)
                case "(", "[", "{":
                    depth += 1
                    current.append(character)
                case ")", "]", "}":
                    depth -= 1
                    current.append(character)
                case delimiter where depth == 0:
                    result.append(current)
                    current = ""
                default:
                    current.append(character)
                }
            }
            if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(current)
            }
            return result
        }
    }
#endif
