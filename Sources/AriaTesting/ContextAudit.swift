import Aria
import Foundation

// MARK: - RequestRendering

/// Serialises what a provider will actually put in front of the model.
///
/// The point is to measure the *artifact that ships*, not the objects
/// the budget was computed from. Every budget failure worth debugging
/// so far has been the difference between those two:
///
/// * a schema counted once as a schema and sent again inside the tool's
///   description, priced at a prose ratio both times;
/// * a definition compacted after the provider had already captured the
///   original, so the estimate shrank and the request did not;
/// * a tool costed and then dropped, or dropped and then sent.
///
/// A counter that reads `ToolDefinition` cannot see any of those. A
/// counter that reads the rendered text sees all of them, which is why
/// the audit renders first and counts second.
public enum RequestRendering {
    /// Approximate what a chat template emits for a request.
    ///
    /// Deliberately provider-agnostic and deliberately not exact: no
    /// two templates agree on separators, and the audit is looking for
    /// *large* discrepancies — a 4x under-count, not a 4% one. Being
    /// roughly right about the whole is worth more than being exactly
    /// right about one provider's punctuation.
    public static func render(tools: [AnyTool], messages: [Message]) -> String {
        var parts: [String] = []
        for tool in tools {
            parts.append(self.render(tool: tool.definition))
        }
        for message in messages {
            parts.append(self.render(message: message))
        }
        return parts.joined(separator: "\n")
    }

    public static func render(tool: ToolDefinition) -> String {
        var parts = ["{\"name\":\"\(tool.name)\",\"description\":\"\(tool.description)\""]
        if let data = try? JSONEncoder().encode(tool.inputSchema),
           let schema = String(data: data, encoding: .utf8) {
            parts.append(",\"parameters\":\(schema)")
        }
        if let guidance = tool.promptGuidance {
            parts.append(",\"guidance\":\"\(guidance)\"")
        }
        parts.append("}")
        return parts.joined()
    }

    public static func render(message: Message) -> String {
        var parts = ["<|\(message.role)|>", message.textContent]
        for call in message.toolCalls {
            parts.append("{\"name\":\"\(call.name)\",\"arguments\":")
            if let data = try? call.arguments.canonicalData(),
               let json = String(data: data, encoding: .utf8) {
                parts.append(json)
            }
            parts.append("}")
        }
        return parts.joined()
    }
}

// MARK: - ContextAudit

/// Checks a token estimate against the request it is supposed to
/// describe.
///
/// The estimate is the most load-bearing number in the context layer —
/// every trim, every cap and every drop is arithmetic on top of it — and
/// until now nothing verified it. When it was wrong the symptom appeared
/// somewhere else entirely: a provider refusing a turn that the budget
/// had declared comfortable, with the budget still reporting itself
/// satisfied afterwards.
///
/// Direction matters. Over-estimating wastes budget and sends fewer
/// tools; under-estimating overflows the window and loses the whole
/// turn. So the assertions are one-sided: the estimate may be
/// conservative, and may not be optimistic.
public struct ContextAudit: Sendable {
    // MARK: Lifecycle

    /// - Parameter reference: Ground truth over the rendered request.
    ///   Supply a real tokenizer where one is available; the default is
    ///   a character heuristic tuned for JSON-dense text, which is
    ///   enough to catch order-of-magnitude errors and not enough to
    ///   catch small ones.
    public init(
        counter: any TokenCounter = HeuristicTokenCounter(),
        reference: @escaping @Sendable (String) -> Int = ContextAudit.defaultReference
    ) {
        self.counter = counter
        self.reference = reference
    }

    // MARK: Public

    public struct Report: Sendable {
        public let estimatedTokens: Int
        public let referenceTokens: Int
        public let renderedCharacters: Int

        /// How far the estimate falls short. Above 1 means the request
        /// is bigger than the budget believed.
        public var underestimateFactor: Double {
            guard self.estimatedTokens > 0 else {
                return self.referenceTokens > 0 ? .infinity : 1
            }
            return Double(self.referenceTokens) / Double(self.estimatedTokens)
        }

        /// Characters the estimate implicitly priced per token. A value
        /// far above the counter's configured ratio means it is reading
        /// something other than what ships.
        public var impliedCharactersPerToken: Double {
            guard self.estimatedTokens > 0 else {
                return .infinity
            }
            return Double(self.renderedCharacters) / Double(self.estimatedTokens)
        }

        public func summary() -> String {
            String(
                format: "estimated %d · reference %d · %.2fx · %.1f chars/token implied",
                self.estimatedTokens,
                self.referenceTokens,
                self.underestimateFactor,
                self.impliedCharactersPerToken
            )
        }
    }

    /// JSON tokenises far denser than prose — quoted keys, braces and
    /// nesting each become their own token. Measured against real
    /// tokenizers this lands near three characters per token; the audit
    /// uses it only to spot gross errors.
    public static let defaultReference: @Sendable (String) -> Int = { text in
        max(1, Int((Double(text.count) / 3.0).rounded(.up)))
    }

    /// Audit a whole assembled request.
    public func audit(_ assembled: AssembledContext) -> Report {
        let rendered = RequestRendering.render(
            tools: assembled.tools,
            messages: assembled.messages
        )
        let estimated = assembled.tools.reduce(0) { $0 + self.counter.count(tool: $1.definition) }
            + assembled.messages.reduce(0) { $0 + self.counter.count(message: $1) }
        return Report(
            estimatedTokens: estimated,
            referenceTokens: self.reference(rendered),
            renderedCharacters: rendered.count
        )
    }

    /// Audit one tool in isolation — the granularity that localises a
    /// bad estimate to the definition that caused it.
    public func audit(tool: ToolDefinition) -> Report {
        let rendered = RequestRendering.render(tool: tool)
        return Report(
            estimatedTokens: self.counter.count(tool: tool),
            referenceTokens: self.reference(rendered),
            renderedCharacters: rendered.count
        )
    }

    // MARK: Private

    private let counter: any TokenCounter
    private let reference: @Sendable (String) -> Int
}
