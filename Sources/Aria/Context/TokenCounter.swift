import Foundation

// MARK: - TokenCounter

/// Estimates token cost for the pieces of a request.
///
/// Exact counts need a vendor tokenizer, which core deliberately does
/// not carry. Estimates are enough to allocate against a budget,
/// provided they err in the safe direction — over-counting trims a
/// little more history than strictly necessary, while under-counting
/// overflows the model.
public protocol TokenCounter: Sendable {
    /// Tokens for a free-text string (prompts, message bodies).
    func count(text: String) -> Int

    /// Tokens for a tool definition as the provider will serialize it.
    ///
    /// Separate from `count(text:)` because the two tokenize very
    /// differently, and because tool definitions routinely dominate the
    /// request. A chat template renders these as JSON — punctuation,
    /// quoted keys, and nesting all tokenize far denser than prose, so
    /// measuring a schema with a prose ratio understates it badly.
    func count(tool: ToolDefinition) -> Int
}

// MARK: - HeuristicTokenCounter

/// Character-ratio estimator. The default when no tokenizer is injected.
///
/// Prose runs about 4 characters per token in English. Serialized JSON
/// runs denser — closer to 3 — because structural characters each tend
/// to cost a token while carrying no words. Applying the prose ratio to
/// tool schemas is how a tool surface can be a third larger than a
/// naive estimate suggests.
public struct HeuristicTokenCounter: TokenCounter {
    // MARK: Lifecycle

    public init(
        charactersPerTextToken: Double = 4.0,
        charactersPerSchemaToken: Double = 3.0
    ) {
        self.charactersPerTextToken = max(1.0, charactersPerTextToken)
        self.charactersPerSchemaToken = max(1.0, charactersPerSchemaToken)
    }

    // MARK: Public

    public func count(text: String) -> Int {
        guard !text.isEmpty else {
            return 0
        }
        return max(1, Int((Double(text.count) / self.charactersPerTextToken).rounded(.up)))
    }

    public func count(tool: ToolDefinition) -> Int {
        // Name and description are prose; the schema is JSON. Measure
        // each with its own ratio rather than averaging them.
        var total = self.count(text: tool.name)
        total += self.count(text: tool.description)
        if let guidance = tool.promptGuidance {
            total += self.count(text: guidance)
        }
        total += self.countSchema(tool.inputSchema)
        if let output = tool.outputSchema {
            total += self.countSchema(output)
        }
        // Per-tool envelope the template adds around each entry
        // (braces, key names, separators). Small, but multiplied by a
        // large tool surface it stops being noise.
        return total + Self.perToolEnvelopeTokens
    }

    // MARK: Private

    /// Structural overhead a chat template spends per tool entry.
    private static let perToolEnvelopeTokens = 8

    private let charactersPerTextToken: Double
    private let charactersPerSchemaToken: Double

    private func countSchema(_ schema: JSONSchema) -> Int {
        guard let data = try? JSONEncoder().encode(schema) else {
            // Unencodable schema shouldn't silently cost zero — that
            // would let a tool slip past the budget entirely.
            return Self.perToolEnvelopeTokens
        }
        let characters = Double(data.count)
        return max(1, Int((characters / self.charactersPerSchemaToken).rounded(.up)))
    }
}
