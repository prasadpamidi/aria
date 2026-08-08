import Foundation

// MARK: - ToolArgumentDecoder

/// Turns a model-emitted argument payload into a callable argument map.
///
/// Bridges that vend many runtime-named tools through one compile-time
/// `@Generable` shape (MCP servers, JS plugins, saved workflows) can't
/// hand the model a typed argument struct. They ask it for a *string*
/// containing JSON instead, and that string is the least reliable value
/// in the whole loop: it is free-form text produced by a small model
/// that was shown a schema and asked to imitate it.
///
/// **The failure this exists to prevent.** A tool with no parameters —
/// `get_fasting_status`, `get_profile`, `get_daily_briefing` — has no
/// natural payload. Asked for "a JSON object matching the input
/// schema," a model with nothing to encode writes prose: `none`, `no
/// arguments`, a fenced block, the schema itself. A bridge that
/// requires strict JSON then refuses a call that needed no arguments at
/// all, and the model, told only that its arguments were invalid,
/// apologises to the user for a capability it actually had. Every
/// zero-argument tool on a server is one bad guess away from that.
///
/// So the schema decides how hard to fail. A payload that can't be
/// parsed is fatal only when the tool actually needed something: if
/// nothing is required, an unreadable payload means the same as an
/// empty one, and the call proceeds. When it *is* fatal, the error
/// carries the raw payload — a bridge that hides what the model wrote
/// makes every future occurrence equally undiagnosable.
public enum ToolArgumentDecoder {
    // MARK: Public

    /// What had to be done to the payload to make it callable.
    ///
    /// Worth logging: a tool that is always `.defaulted` is one whose
    /// description isn't telling the model what to write.
    public enum Repair: String, Sendable, Equatable, CaseIterable {
        /// Parsed as sent.
        case none
        /// Payload was blank or whitespace.
        case blank
        /// Payload was wrapped in a Markdown code fence.
        case unfenced
        /// Payload was a JSON *string* whose contents were themselves
        /// JSON — a model encoding its arguments twice.
        case unwrapped
        /// A JSON object was recovered from surrounding prose.
        case extracted
        /// Nothing was recoverable, and the tool required nothing.
        case defaulted
    }

    public struct Decoded: Sendable, Equatable {
        public let arguments: [String: JSONValue]
        public let repair: Repair

        public var value: JSONValue { .object(self.arguments) }
    }

    /// Only raised when the tool genuinely needed arguments it did not
    /// get. Both cases quote the payload verbatim so the model's next
    /// attempt is informed and a human reading a trace can see the
    /// actual text rather than a description of it.
    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible {
        case unreadable(raw: String, required: [String])
        case notAnObject(raw: String, required: [String])

        public var description: String {
            switch self {
            case let .unreadable(raw, required):
                "Arguments were not valid JSON. Required: \(Self.list(required)). Send a JSON object, e.g. \(Self.example(required)). Received: \(Self.quote(raw))"
            case let .notAnObject(raw, required):
                "Arguments must be a JSON object, not a bare value. Required: \(Self.list(required)). Send e.g. \(Self.example(required)). Received: \(Self.quote(raw))"
            }
        }

        // MARK: Private

        private static func list(_ required: [String]) -> String {
            required.isEmpty ? "(none)" : required.joined(separator: ", ")
        }

        /// A concrete shape beats a restatement of the rule — the model
        /// already read the rule and produced this payload anyway.
        private static func example(_ required: [String]) -> String {
            guard let first = required.first else {
                return "{}"
            }
            return "{\"\(first)\": …}"
        }

        /// Bounded: a model that pasted its whole reasoning into the
        /// arguments field shouldn't blow out the next prompt.
        private static func quote(_ raw: String) -> String {
            let limit = 200
            guard raw.count > limit else {
                return "\"\(raw)\""
            }
            return "\"\(raw.prefix(limit))…\" (\(raw.count) chars)"
        }
    }

    /// Decode `raw` into an argument map, repairing what can be
    /// repaired and failing only when the tool needed more than it got.
    public static func decode(
        _ raw: String,
        for schema: JSONSchema
    ) -> Result<Decoded, Failure> {
        let required = Self.requiredProperties(of: schema)

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .success(Decoded(arguments: [:], repair: .blank))
        }

        var repair = Repair.none
        var text = trimmed
        if let unfenced = Self.stripFence(text) {
            text = unfenced
            repair = .unfenced
        }

        if let parsed = Self.parse(text) {
            // A model that encodes its arguments twice sends a JSON
            // string whose contents are the real object.
            if case let .string(inner) = parsed,
               let unwrapped = Self.parse(inner.trimmingCharacters(in: .whitespacesAndNewlines)),
               case let .object(map) = unwrapped {
                return .success(Decoded(arguments: map, repair: .unwrapped))
            }
            if case let .object(map) = parsed {
                return .success(Decoded(arguments: map, repair: repair))
            }
        }

        // Either unparseable or parsed to a bare value. Prose wrapped
        // around a real object is common enough to be worth one more
        // attempt before giving up.
        if let object = Self.firstBalancedObject(in: text),
           let parsed = Self.parse(object),
           case let .object(map) = parsed {
            return .success(Decoded(arguments: map, repair: .extracted))
        }

        // Nothing recoverable. Fatal only if the tool needed something.
        guard required.isEmpty else {
            return .failure(
                Self.parse(text) == nil
                    ? .unreadable(raw: raw, required: required)
                    : .notAnObject(raw: raw, required: required)
            )
        }
        return .success(Decoded(arguments: [:], repair: .defaulted))
    }

    /// Property names a caller must supply, or `[]` for schemas that
    /// demand nothing. Non-object schemas require nothing by
    /// definition, so they decode tolerantly.
    public static func requiredProperties(of schema: JSONSchema) -> [String] {
        guard case let .object(_, required, _, _) = schema else {
            return []
        }
        return required
    }

    /// The line a bridge should append to a tool's description so the
    /// model knows what to write. Stating the empty object explicitly
    /// is what keeps a zero-argument tool from being improvised at.
    public static func payloadGuidance(
        for schema: JSONSchema,
        field: String = "argumentsJSON"
    ) -> String {
        guard case let .object(properties, required, _, _) = schema,
              !properties.isEmpty else {
            return "Takes no arguments. Send \(field): \"{}\"."
        }
        guard let first = required.first else {
            return "All arguments are optional. Send \(field): \"{}\" to accept the defaults."
        }
        return "Send \(field) as a JSON object, e.g. {\"\(first)\": …}."
    }

    // MARK: Private

    /// Strip a Markdown code fence, returning `nil` when there isn't
    /// one so the caller can tell repaired input from clean input.
    private static func stripFence(_ text: String) -> String? {
        guard text.hasPrefix("```") else {
            return nil
        }
        var body = text.drop(while: { $0 == "`" })
        // An opening fence may carry a language tag on its own line.
        if let newline = body.firstIndex(of: "\n") {
            let tag = body[body.startIndex ..< newline]
            if tag.allSatisfy({ $0.isLetter || $0.isNumber }) {
                body = body[body.index(after: newline)...]
            }
        }
        while body.hasSuffix("`") {
            body = body.dropLast()
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse permissively — top-level fragments included — so the
    /// caller decides what shapes are acceptable rather than the parser
    /// rejecting them as malformed.
    private static func parse(_ text: String) -> JSONValue? {
        guard !text.isEmpty,
              let object = try? JSONSerialization.jsonObject(
                  with: Data(text.utf8),
                  options: [.fragmentsAllowed]
              ) else {
            return nil
        }
        return Self.convert(object)
    }

    /// Find the first balanced `{…}` span, honouring string literals so
    /// a brace inside a quoted value doesn't end the scan early.
    private static func firstBalancedObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else {
            return nil
        }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\", inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start ... index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func convert(_ value: Any) -> JSONValue {
        if value is NSNull {
            return .null
        }
        // `NSNumber` bridges to Bool, Int and Double alike, so the
        // boolean check has to precede the numeric ones or `true`
        // decodes as `1`.
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if let integer = Int64(exactly: number) {
                return .integer(integer)
            }
            return .number(number.doubleValue)
        }
        if let string = value as? String {
            return .string(string)
        }
        if let array = value as? [Any] {
            return .array(array.map(Self.convert))
        }
        if let dictionary = value as? [String: Any] {
            return .object(dictionary.mapValues(Self.convert))
        }
        return .null
    }
}
