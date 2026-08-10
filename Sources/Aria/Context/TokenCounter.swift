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

    /// Tokens for a whole message as the provider will serialize it.
    ///
    /// Not the same as `count(text:)` on its body. A message carries a
    /// role marker and separators, and an assistant turn that requests
    /// a tool often has *no* text at all — its entire cost is the call
    /// name and arguments. Budgeting history by body text alone
    /// therefore prices a tool-calling turn at nearly zero, which is
    /// exactly the turn most likely to overflow.
    func count(message: Message) -> Int
}

extension TokenCounter {
    /// Role marker plus separators the chat template spends per
    /// message. Small individually; a tool-calling turn produces two
    /// messages per call, so it compounds fast.
    public var perMessageEnvelopeTokens: Int {
        4
    }

    /// What one image costs in the model's context.
    ///
    /// Vision models price an image by tile count — a 1024×1024 image
    /// runs to roughly a thousand tokens on the Qwen-VL family — and
    /// nothing about that is derivable from the bytes we hold. So this
    /// is a constant, and a deliberately large one: an image counted at
    /// zero is invisible to every budget decision downstream, which is
    /// what happened before this existed. History windowing never
    /// dropped an image message because it looked free, and the request
    /// overflowed with the budget reporting itself satisfied.
    ///
    /// Over-charging costs a few tools. Under-charging costs the turn.
    public var tokensPerImage: Int {
        1024
    }

    public func count(message: Message) -> Int {
        var total = self.count(text: message.textContent)
        total += message.content.reduce(0) { running, part in
            if case .image = part {
                return running + self.tokensPerImage
            }
            return running
        }
        for call in message.toolCalls {
            total += self.count(text: call.name)
            if let data = try? call.arguments.canonicalData() {
                // Arguments are JSON, so they tokenize denser than
                // prose — same reason schemas get their own ratio.
                total += max(1, Int((Double(data.count) / 3.0).rounded(.up)))
            }
        }
        return total + self.perMessageEnvelopeTokens
    }
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
