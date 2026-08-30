import Foundation

// MARK: - ToolCompaction

/// How much of a tool definition to give up when it will not fit.
///
/// Ordered by what it costs the model. Each level keeps every *callable*
/// property of the schema — names, types, and the required list are
/// never touched — so a call the model could have made before it stays
/// legal after. What goes is guidance: the prose that helps it choose
/// well, then the optional surface it could have used.
///
/// That ordering is the whole design. A tool the model calls with worse
/// arguments is recoverable; a tool whose arguments no longer validate
/// is not.
public enum ToolCompaction: Int, Sendable, Comparable, CaseIterable {
    /// Exactly as the server published it.
    case none = 0
    /// Drop per-property descriptions. The parameter names survive, and
    /// on a well-named schema (`location`, `days`, `units`) they carry
    /// most of what the description said anyway.
    case propertyDescriptions = 1
    /// Also shorten the tool's own description to its first sentence.
    ///
    /// Tool descriptions are written for a catalogue page and are
    /// front-loaded by convention: the opening sentence says what it
    /// does, the rest is caveats and examples. Selection has already
    /// happened by the time the model reads this, so the sentence that
    /// distinguishes the tool matters more than the paragraph.
    case shortDescription = 2
    /// Also drop optional properties, keeping the required ones.
    ///
    /// The model loses the ability to pass them — it does not lose the
    /// ability to call the tool. Last because it is the only level that
    /// removes capability rather than guidance.
    case requiredOnly = 3

    // MARK: Public

    public static func < (lhs: ToolCompaction, rhs: ToolCompaction) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - ToolDefinitionCompactor

/// Shrinks tool definitions that are too large to send whole.
///
/// A single MCP tool schema is routinely a thousand tokens — a full
/// paragraph of description plus a dozen documented parameters. On a
/// 4,096-token window that is a quarter of everything the model will
/// ever see, for one tool it may not even call. Six of them put 5,845
/// tokens into that window and the request was refused outright.
///
/// Budgeting cannot solve this. A share that fits six such tools does
/// not exist, so the choice was between refusing to send them and
/// sending one at a time; both are bad, and neither addresses the fact
/// that most of those tokens are prose the model does not need in order
/// to make the call.
///
/// This is not truncation. Truncating a schema produces one the model
/// cannot satisfy; this removes only what is safe to remove, and stops
/// at the first level that fits.
public enum ToolDefinitionCompactor {
    // MARK: Public

    /// Compact `definition` to the lightest level that fits `limit`.
    ///
    /// Returns the original when it already fits, and the most compact
    /// form when nothing does — an oversized tool still goes, because
    /// a tool the model cannot call is better than a turn that cannot
    /// act.
    public static func compact(
        _ definition: ToolDefinition,
        toFit limit: Int,
        counter: any TokenCounter
    ) -> (definition: ToolDefinition, applied: ToolCompaction) {
        for level in ToolCompaction.allCases {
            let candidate = self.apply(level, to: definition)
            if counter.count(tool: candidate) <= limit {
                return (candidate, level)
            }
        }
        return (self.apply(.requiredOnly, to: definition), .requiredOnly)
    }

    /// Apply one level, unconditionally.
    public static func apply(
        _ level: ToolCompaction,
        to definition: ToolDefinition
    ) -> ToolDefinition {
        guard level != .none else {
            return definition
        }
        return ToolDefinition(
            name: definition.name,
            description: level >= .shortDescription
                ? self.firstSentence(of: definition.description)
                : definition.description,
            inputSchema: self.compact(schema: definition.inputSchema, level: level)
        )
    }

    // MARK: Private

    /// Long enough for a real opening sentence, short enough that a
    /// description written as one long run-on still shrinks.
    private static let sentenceCap = 200

    private static func compact(schema: JSONSchema, level: ToolCompaction) -> JSONSchema {
        switch schema {
        case let .object(properties, required, description, additionalProperties):
            let requiredSet = Set(required)
            var kept: [String: JSONSchema] = [:]
            for (name, value) in properties {
                // Required properties are never dropped. Removing one
                // makes every call invalid, which is the one outcome
                // this must not produce.
                if level >= .requiredOnly, !requiredSet.contains(name) {
                    continue
                }
                kept[name] = self.compact(schema: value, level: level)
            }
            return .object(
                properties: kept,
                required: required,
                description: level >= .propertyDescriptions ? nil : description,
                additionalProperties: additionalProperties
            )
        case let .string(description, enumValues):
            // Enum values survive at every level: they are not
            // documentation, they are the set of legal inputs, and a
            // model guessing outside it produces a call that fails.
            return .string(
                description: level >= .propertyDescriptions ? nil : description,
                enumValues: enumValues
            )
        case let .number(description):
            return .number(description: level >= .propertyDescriptions ? nil : description)
        case let .integer(description):
            return .integer(description: level >= .propertyDescriptions ? nil : description)
        case let .boolean(description):
            return .boolean(description: level >= .propertyDescriptions ? nil : description)
        case let .array(items, description):
            return .array(
                items: self.compact(schema: items, level: level),
                description: level >= .propertyDescriptions ? nil : description
            )
        case let .oneOf(options):
            return .oneOf(options.map { self.compact(schema: $0, level: level) })
        case let .anyOf(options):
            return .anyOf(options.map { self.compact(schema: $0, level: level) })
        case let .allOf(options):
            return .allOf(options.map { self.compact(schema: $0, level: level) })
        case .null:
            return schema
        }
    }

    /// First sentence, or a hard cap when the text has no sentence
    /// break — some servers write a single unpunctuated paragraph.
    private static func firstSentence(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return trimmed
        }
        if let end = trimmed.firstIndex(where: { $0 == "." || $0 == "\n" }) {
            let sentence = String(trimmed[trimmed.startIndex...end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A three-word opener is a heading, not a description.
            if sentence.count >= 24 {
                return sentence
            }
        }
        guard trimmed.count > Self.sentenceCap else {
            return trimmed
        }
        return String(trimmed.prefix(Self.sentenceCap)) + "…"
    }
}
