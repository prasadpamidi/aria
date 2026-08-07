import Foundation

// MARK: - AssembledContext

/// The finished request: exactly what goes to the provider, plus an
/// account of how the budget was spent.
public struct AssembledContext: Sendable {
    // MARK: Lifecycle

    public init(
        messages: [Message],
        tools: [AnyTool],
        allocation: ContextAllocation
    ) {
        self.messages = messages
        self.tools = tools
        self.allocation = allocation
    }

    // MARK: Public

    /// Final message list, system prompt already prepended.
    public let messages: [Message]

    /// Tools that survived selection, still executable.
    public let tools: [AnyTool]

    /// What this cost. Surface it in diagnostics.
    public let allocation: ContextAllocation
}

// MARK: - ContextAssembler

/// Decides what fits in a single provider call.
///
/// Placement is the whole point. Middleware runs before
/// `AgentStep` prepends the system prompt, and tool definitions never
/// enter `AgentState` at all — they travel to the provider separately
/// and are serialized by its chat template. Any component that runs
/// earlier is therefore structurally unable to see most of the request
/// it claims to bound. The assembler runs where all three converge.
public protocol ContextAssembler: Sendable {
    func assemble(
        systemPrompt: String?,
        tools: [AnyTool],
        state: AgentState,
        budget: ContextBudget
    ) async -> AssembledContext
}

// MARK: - DefaultContextAssembler

/// Allocates in priority order: instructions, tools, then history
/// newest-first.
///
/// Instructions are never trimmed — a partial system prompt changes the
/// agent's behaviour in ways that are far worse than a short history.
/// History is trimmed instead, oldest first, because recency dominates
/// relevance in conversation.
public struct DefaultContextAssembler: ContextAssembler {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - selector: Ranks tools per turn. Only consulted when
    ///     `budget.maxTools` is set; an unbounded budget sends
    ///     everything and skips ranking entirely.
    ///   - tokenCounter: Estimates cost.
    ///   - pinnedToolNames: Tools that bypass selection unconditionally.
    ///
    ///     Some tools are gateways rather than capabilities — a
    ///     `load_skill` that fetches instructions on demand is
    ///     self-defeating to rank away, because the query that needs it
    ///     rarely resembles its description.
    ///   - onAllocation: Called with the breakdown after each assembly.
    ///
    ///     Without this the accounting is computed and discarded, which
    ///     leaves the cost of a turn as invisible as it was before any
    ///     of this existed — a consumer can enforce a budget but not
    ///     show anyone what it spent. Delivered as a callback rather
    ///     than an `AgentEvent` case because adding a case to a public
    ///     enum breaks exhaustive switches in shipped consumers.
    ///   - onAssembled: Receives the finished request — the exact
    ///     messages and tools handed to the provider.
    ///
    ///     Counts answer "how much"; only the text answers "what". The
    ///     system prompt the model actually reads is composed here, by
    ///     folding tool guidance into the caller's prompt, so no
    ///     consumer can reconstruct it from what it passed in. A
    ///     diagnostic UI that shows token totals but not the prompt
    ///     leaves the most common question — "what did the model
    ///     actually see?" — unanswerable.
    public init(
        selector: any ToolSelector = LexicalToolSelector(),
        tokenCounter: any TokenCounter = HeuristicTokenCounter(),
        pinnedToolNames: Set<String> = [],
        onAllocation: (@Sendable (ContextAllocation) -> Void)? = nil,
        onAssembled: (@Sendable (AssembledContext) -> Void)? = nil
    ) {
        self.selector = selector
        self.tokenCounter = tokenCounter
        self.pinnedToolNames = pinnedToolNames
        self.onAllocation = onAllocation
        self.onAssembled = onAssembled
    }

    // MARK: Public

    public func assemble(
        systemPrompt: String?,
        tools: [AnyTool],
        state: AgentState,
        budget: ContextBudget
    ) async -> AssembledContext {
        let selectedTools = await self.selectTools(
            from: tools,
            state: state,
            budget: budget
        )

        // Guidance rides with the tools that survived, so instructions
        // can never describe a tool the model wasn't given. Consumers
        // previously hand-wrote tool policy into the system prompt,
        // where it outlived the tool it described and — on small models
        // — got mistaken for content to reproduce.
        let prompt = Self.compose(
            systemPrompt: systemPrompt,
            guidanceFrom: selectedTools
        )

        let promptTokens = prompt.map { self.tokenCounter.count(text: $0) } ?? 0
        let toolTokens = selectedTools.reduce(0) { $0 + self.tokenCounter.count(tool: $1.definition) }

        let remaining = max(0, budget.available - promptTokens - toolTokens)
        let history = self.windowMessages(state.messages, limit: remaining)

        var messages: [Message] = []
        if let prompt, !prompt.isEmpty {
            messages.append(.system(prompt))
        }
        messages.append(contentsOf: history.messages)

        let allocation = ContextAllocation(
            systemPromptTokens: promptTokens,
            toolTokens: toolTokens,
            memoryTokens: 0,
            historyTokens: history.tokens,
            budgetAvailable: budget.available,
            toolsOffered: tools.count,
            toolsSelected: selectedTools.count,
            selectedToolNames: selectedTools.map(\.name),
            messagesDropped: history.dropped,
            memoriesDropped: 0
        )
        self.onAllocation?(allocation)

        let assembled = AssembledContext(
            messages: messages,
            tools: selectedTools,
            allocation: allocation
        )
        self.onAssembled?(assembled)
        return assembled
    }

    // MARK: Private

    /// Outcome of trimming history to fit.
    private struct WindowedHistory {
        let messages: [Message]
        let dropped: Int
        let tokens: Int
    }

    private let selector: any ToolSelector
    private let tokenCounter: any TokenCounter
    private let pinnedToolNames: Set<String>
    private let onAllocation: (@Sendable (ContextAllocation) -> Void)?
    private let onAssembled: (@Sendable (AssembledContext) -> Void)?

    /// Compose the system prompt with guidance from surviving tools.
    private static func compose(
        systemPrompt: String?,
        guidanceFrom tools: [AnyTool]
    ) -> String? {
        let guidance = tools.compactMap { tool -> String? in
            guard let text = tool.definition.promptGuidance, !text.isEmpty else {
                return nil
            }
            return "- \(tool.definition.name): \(text)"
        }
        guard !guidance.isEmpty else {
            return systemPrompt
        }

        let block = (["## Tool guidance"] + guidance).joined(separator: "\n")
        guard let systemPrompt, !systemPrompt.isEmpty else {
            return block
        }
        return "\(systemPrompt)\n\n\(block)"
    }

    /// Tool names this run has already invoked.
    ///
    /// A tool selected on one step must remain present on the next, or
    /// the result it produced becomes unresolvable and the model is
    /// left reading a reply to a call it can no longer see. Ranking is
    /// per-turn; availability has to be per-run.
    private static func invokedToolNames(in messages: [Message]) -> Set<String> {
        var names: Set<String> = []
        for message in messages {
            for call in message.toolCalls {
                names.insert(call.name)
            }
        }
        return names
    }

    /// Latest user text, used as the ranking query.
    private static func latestUserText(in messages: [Message]) -> String {
        messages.last { $0.role == .user }?.textContent ?? ""
    }

    private func selectTools(
        from tools: [AnyTool],
        state: AgentState,
        budget: ContextBudget
    ) async -> [AnyTool] {
        guard !tools.isEmpty else {
            return []
        }

        let maxTools = budget.maxTools ?? Int.max
        let ceiling = budget.toolTokenLimit

        // Nothing to relieve: everything fits under both limits, so
        // ranking could only remove tools the model might need.
        //
        // The share ceiling applies whether or not a count cap is set.
        // Gating it on `maxTools` meant an uncapped budget sent every
        // tool no matter how large the surface grew — the exact
        // pressure this mechanism exists to relieve, and precisely
        // where it was absent.
        let totalCost = tools.reduce(0) { $0 + self.tokenCounter.count(tool: $1.definition) }
        if tools.count <= maxTools, totalCost <= ceiling {
            return tools
        }

        let required = self.pinnedToolNames
            .union(Self.invokedToolNames(in: state.messages))
        let requiredTools = tools.filter { required.contains($0.name) }
        let candidates = tools.filter { !required.contains($0.name) }

        // Required tools can legitimately exceed the cap. Correctness
        // beats the budget here: dropping a tool the run already called
        // breaks the conversation outright, while overshooting the cap
        // only costs tokens.
        let room = maxTools == Int.max ? candidates.count : max(0, maxTools - requiredTools.count)
        guard room > 0, !candidates.isEmpty else {
            return requiredTools
        }

        let ranked = await self.selector.select(
            from: candidates.map(\.definition),
            query: Self.latestUserText(in: state.messages),
            limit: room
        )
        let byName = Dictionary(candidates.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var selected = requiredTools + ranked.compactMap { byName[$0.name] }

        // Rank, then fill.
        //
        // Ranking decides order; the budget decides how many. Sending
        // only what matched lexically discards tools that would have
        // cost nothing to include — observed in practice as a
        // twenty-tool surface reduced to a single match on the word
        // "quick", with 97% of the window left empty and the tool the
        // user actually needed among the discarded.
        //
        // A miss in ranking is then merely an ordering mistake rather
        // than an amputation, which matters because lexical matching
        // misses often.
        var chosen = Set(selected.map(\.name))
        var spent = selected.reduce(0) { $0 + self.tokenCounter.count(tool: $1.definition) }

        for tool in candidates where !chosen.contains(tool.name) {
            guard selected.count < maxTools else {
                break
            }
            let cost = self.tokenCounter.count(tool: tool.definition)
            guard spent + cost <= ceiling else {
                continue
            }
            selected.append(tool)
            chosen.insert(tool.name)
            spent += cost
        }

        return selected
    }

    /// Trim oldest history until it fits, preserving system messages.
    private func windowMessages(
        _ messages: [Message],
        limit: Int
    ) -> WindowedHistory {
        let cost = { (message: Message) in self.tokenCounter.count(text: message.textContent) }
        var total = messages.reduce(0) { $0 + cost($1) }
        guard total > limit else {
            return WindowedHistory(messages: messages, dropped: 0, tokens: total)
        }

        var kept = messages
        var dropped = 0
        // Drop oldest non-system messages first. System messages carry
        // instructions and recalled context; removing them changes
        // behaviour rather than merely shortening it.
        var index = 0
        while total > limit, index < kept.count {
            if kept[index].role == .system {
                index += 1
                continue
            }
            // Never drop the final message — the model needs something
            // to respond to, even if it alone exceeds the budget.
            if index == kept.count - 1 {
                break
            }
            total -= cost(kept[index])
            kept.remove(at: index)
            dropped += 1
        }

        // A tool result whose originating assistant call was just
        // dropped is worse than useless: the model sees an answer to a
        // question it has no record of asking.
        while let first = kept.first(where: { $0.role != .system }),
              first.role == .tool,
              kept.count > 1,
              let position = kept.firstIndex(where: { $0.role != .system }) {
            total -= cost(kept[position])
            kept.remove(at: position)
            dropped += 1
        }

        return WindowedHistory(messages: kept, dropped: dropped, tokens: total)
    }
}
