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
        unrankedFillLimit: Int? = nil,
        memoryMessagePrefix: String? = nil,
        onAllocation: (@Sendable (ContextAllocation) -> Void)? = nil,
        onAssembled: (@Sendable (AssembledContext) -> Void)? = nil
    ) {
        self.selector = selector
        self.tokenCounter = tokenCounter
        self.pinnedToolNames = pinnedToolNames
        self.unrankedFillLimit = unrankedFillLimit
        self.memoryMessagePrefix = memoryMessagePrefix
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
        let (ranked, rankedNames) = await self.selectTools(
            from: tools,
            state: state,
            budget: budget
        )
        // Last line of defence: tools must leave room for the message
        // they are meant to answer.
        //
        // `toolTokenLimit` is a *share* and is deliberately breakable —
        // sending no usable tool is worse than overspending the share.
        // `available` is not. Without a hard bound the two rules
        // compose into the worst outcome: a run selected three MCP
        // tools worth 4,533 tokens against a 1,198 share and a 2,996
        // budget, history collapsed to nothing to make room, and the
        // provider refused the request at 4,727 of 4,096 — so the turn
        // failed anyway, having thrown away the conversation first.
        let selectedTools = self.withinHardLimit(
            ranked,
            systemPrompt: systemPrompt,
            budget: budget,
            state: state
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
        // Bound each result before windowing. Windowing can only drop
        // whole messages oldest-first and never drops the newest, so a
        // few very large recent results are beyond its reach entirely —
        // it trims the conversation down to nothing and still overflows.
        let (bounded, truncated) = self.boundToolResults(
            Self.strippingPastReasoning(from: state.messages),
            limit: budget.toolResultTokenLimit
        )
        let history = self.windowMessages(bounded, limit: remaining)

        var messages: [Message] = []
        if let prompt, !prompt.isEmpty {
            messages.append(.system(prompt))
        }
        messages.append(contentsOf: history.messages)

        let memoryTokens = self.memoryTokens(in: history.messages)
        let allocation = ContextAllocation(
            systemPromptTokens: promptTokens,
            toolTokens: toolTokens,
            memoryTokens: memoryTokens,
            historyTokens: max(0, history.tokens - memoryTokens),
            budgetAvailable: budget.available,
            toolsOffered: tools.count,
            toolsSelected: selectedTools.count,
            selectedToolNames: selectedTools.map(\.name),
            offeredToolNames: tools.map(\.name),
            rankedToolNames: rankedNames,
            maxTools: budget.maxTools,
            toolTokenLimit: budget.toolTokenLimit,
            messagesDropped: history.dropped,
            memoriesDropped: 0,
            toolResultsTruncated: truncated
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

    /// How many zero-scoring tools to send when ranking finds nothing.
    ///
    /// `nil` fills to the cap, which is right for a ranker that misses
    /// often: "nothing scored" then means "the ranker had nothing to
    /// say", and sending what fits is the only hedge available.
    ///
    /// It is wrong for a ranker that doesn't miss. Fused lexical +
    /// embedding measured 100% recall on the field corpus, so an empty
    /// ranking became evidence rather than noise — and overriding it
    /// has a cost. Told "I live in Dublin, CA", a model was handed
    /// `http_request`, `base64_codec`, `start_fast` and `log_water`,
    /// none of which relate to anything, and answered by inventing a
    /// call to a weather API. Two further turns were spent apologising
    /// for the weather.
    ///
    /// A model with no tools says it cannot help. A model with six
    /// irrelevant ones uses one.
    private let unrankedFillLimit: Int?
    /// Identifies the recalled-memory block so its cost is reported as
    /// memory rather than history.
    ///
    /// `memoryTokens` was hardcoded to zero while `RAGMiddleware`
    /// injected a system message that landed in the history total. The
    /// breakdown therefore said memory cost nothing, on every turn,
    /// which is worse than omitting it — a diagnostic that reports a
    /// confident zero stops anyone looking.
    private let memoryMessagePrefix: String?
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
    /// Scoped to the current turn, which is what "per-run" meant.
    ///
    /// This used to scan the whole thread, so a tool called once was
    /// pinned for the rest of the conversation — and pinned tools lead
    /// the ranking, ahead of anything merely relevant. In the field a
    /// hydration lookup on turn one made `get_hydration_today` the
    /// first tool offered for "What about fasting status?" two turns
    /// later, and it held one of six slots on every turn after.
    ///
    /// A result only needs its tool present while that result is still
    /// being reasoned about, which ends when the user speaks again.
    /// After that the tool is a candidate like any other.
    private static func invokedToolNames(in messages: [Message]) -> Set<String> {
        let turnStart = messages.lastIndex { $0.role == .user }.map { $0 + 1 } ?? 0
        var names: Set<String> = []
        for message in messages[turnStart...] {
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

    /// Drop reasoning blocks from earlier turns.
    ///
    /// A thinking model's `<think>…</think>` is working-out for the
    /// turn that produced it, and chat templates discard it on the next
    /// one — LFM2's strips every assistant block but the last unless
    /// `keep_past_thinking` is set. Counting it anyway is worse than
    /// wasteful: history is budgeted against it, so real messages get
    /// dropped to make room for text the template then throws away.
    ///
    /// Observed on LFM2.5 Thinking: 1,980 tokens of history and four
    /// messages dropped, on a conversation of five short exchanges.
    ///
    /// The current turn keeps its reasoning — the model is still
    /// working inside it, and a step that loses its own scratchpad
    /// starts over.
    private static func strippingPastReasoning(from messages: [Message]) -> [Message] {
        let turnStart = messages.lastIndex { $0.role == .user } ?? messages.count
        return messages.enumerated().map { index, message in
            guard index < turnStart, message.role == .assistant else {
                return message
            }
            let stripped = Self.withoutReasoning(message.textContent)
            guard stripped != message.textContent else {
                return message
            }
            return .assistant(stripped, toolCalls: message.toolCalls)
        }
    }

    /// Remove `<think>…</think>` spans, keeping everything outside them.
    ///
    /// Tolerates an unterminated opener: a stream cut mid-thought would
    /// otherwise leave the whole remainder of the message in place,
    /// which is exactly the oversized case this exists to prevent.
    private static func withoutReasoning(_ text: String) -> String {
        guard text.contains("<think>") else {
            return text
        }
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "<think>") {
            out += rest[rest.startIndex..<open.lowerBound]
            guard let close = rest.range(of: "</think>", range: open.upperBound..<rest.endIndex) else {
                rest = rest[rest.endIndex...]
                break
            }
            rest = rest[close.upperBound...]
        }
        out += rest
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drop ranked tools that do not fit the token ceiling.
    ///
    /// `maxTools` bounds the *count* of tools; this bounds their
    /// *cost*. Both are needed, and only the count was enforced on the
    /// ranked path — the ceiling was consulted for the "everything
    /// already fits" early exit and for filler, then skipped entirely
    /// once ranking returned something. Six tools is a fine cap until
    /// the six are MCP schemas: a connected weather server put 5,845
    /// tokens into a 4,096-token window and the whole turn was
    /// refused, with the budget reporting itself satisfied.
    ///
    /// Required tools are kept regardless. They are pinned or already
    /// invoked this turn, and dropping one breaks the conversation
    /// outright, where overshooting only risks a refusal that trimming
    /// the rest may still avoid.
    ///
    /// Ranked tools are taken in order and the first that does not fit
    /// stops the loop rather than being skipped over. Skipping to a
    /// smaller lower-ranked tool would quietly prefer cheap tools to
    /// relevant ones, which is the opposite of what ranking is for.
    private static func fitting(
        _ selected: [AnyTool],
        required: [AnyTool],
        ceiling: Int,
        cost: (AnyTool) -> Int
    ) -> [AnyTool] {
        let requiredNames = Set(required.map(\.name))
        var kept = required
        var spent = required.reduce(0) { $0 + cost($1) }
        // Compaction is deliberately *not* applied here.
        //
        // `ToolDefinitionCompactor` shrinks a definition safely, and
        // shrinking one changes what the assembler counts. It does not
        // change what every provider sends: `FoundationModelsProvider`
        // builds its typed tools from factory closures supplied at
        // construction, which captured the original description and
        // cannot see a definition swapped afterwards.
        //
        // So compacting here made the budget lie. Measured: a turn
        // priced at 1,366 tokens was refused at 5,362 — the assembler
        // had costed six compacted tools and the provider had sent six
        // full ones. An accurate budget with fewer tools beats an
        // inaccurate budget with more, and a refused turn sends none at
        // all.
        //
        // The compactor keeps its tests and stays ready for the path
        // that can honour it: a provider that builds its tool list from
        // `AssembledContext.tools` rather than from closures fixed at
        // construction.
        for tool in selected where !requiredNames.contains(tool.name) {
            let next = cost(tool)
            guard spent + next <= ceiling else {
                break
            }
            kept.append(tool)
            spent += next
        }

        // If the share admitted nothing, admit the best one anyway.
        //
        // `ceiling` is a *share* of the budget — 40% by default — not
        // the window. Honouring it strictly is right when it costs a
        // fourth tool and wrong when it costs the only one: a turn with
        // no actionable tool cannot do the thing it was asked to do,
        // and no amount of budget discipline redeems that.
        //
        // Observed: a weather question ranked `get_weather_summary`
        // second out of six, and every MCP schema on that server runs
        // to roughly a thousand tokens — over the 1,080 left after the
        // pinned tool. The trim was correct by its own rule and
        // returned a request that could only answer from imagination,
        // which is exactly what the model then did.
        //
        // The one admitted here is the top-ranked, not the smallest
        // that fits. Preferring a cheap tool to a relevant one inverts
        // ranking, and this is a last resort rather than a second
        // policy.
        if kept.count == required.count,
           let best = selected.first(where: { !requiredNames.contains($0.name) }) {
            kept.append(best)
        }
        return kept
    }

    /// Drop tools until the request can physically fit, whatever the
    /// share allowed.
    ///
    /// Tools are dropped from the end — lowest-ranked first — and the
    /// prompt is recomposed each time, because guidance rides with the
    /// tools that survived. The newest message is reserved for: a
    /// request that cannot carry the user's turn is not a smaller
    /// request, it is a broken one.
    private func withinHardLimit(
        _ selected: [AnyTool],
        systemPrompt: String?,
        budget: ContextBudget,
        state: AgentState
    ) -> [AnyTool] {
        let newestTokens = state.messages.last
            .map { self.tokenCounter.count(message: $0) } ?? 0
        var kept = selected
        while !kept.isEmpty {
            let prompt = Self.compose(systemPrompt: systemPrompt, guidanceFrom: kept)
            let promptTokens = prompt.map { self.tokenCounter.count(text: $0) } ?? 0
            let toolTokens = kept.reduce(0) { $0 + self.tokenCounter.count(tool: $1.definition) }
            if promptTokens + toolTokens + newestTokens <= budget.available {
                return kept
            }
            kept.removeLast()
        }
        return kept
    }

    /// Cost of the recalled-memory block, if the caller named it.
    private func memoryTokens(in messages: [Message]) -> Int {
        guard let prefix = memoryMessagePrefix else {
            return 0
        }
        return messages
            .filter { $0.role == .system && $0.textContent.hasPrefix(prefix) }
            .reduce(0) { $0 + self.tokenCounter.count(message: $1) }
    }

    /// - Returns: The tools to send, and — separately — what ranking
    ///   chose *before* the token ceiling trimmed it. The difference
    ///   between those two lists is the whole diagnosis when a tool
    ///   goes missing: empty `ranked` means the ranker found nothing,
    ///   while a full `ranked` and a short `selected` means the budget
    ///   did the cutting. Both look identical from the outside.
    private func selectTools(
        from tools: [AnyTool],
        state: AgentState,
        budget: ContextBudget
    ) async -> (selected: [AnyTool], ranked: [String]) {
        guard !tools.isEmpty else {
            return ([], [])
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
            return (tools, tools.map(\.name))
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
            return (requiredTools, [])
        }

        let query = Self.latestUserText(in: state.messages)
        // An image-only turn has no text to rank against.
        //
        // That is not the same as "nothing matched", and conflating
        // them sent zero tools: the selector returns nothing for an
        // empty query, `unrankedFillLimit: 0` reads that as a decision,
        // and a photo with no caption arrived at the model with no way
        // to act on it. The ranker did not decide anything here — it
        // was never given a question.
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (
                Self.fitting(
                    requiredTools + candidates,
                    required: requiredTools,
                    ceiling: ceiling,
                    cost: { self.tokenCounter.count(tool: $0.definition) }
                ),
                []
            )
        }
        let ranked = await self.selector.select(
            from: candidates.map(\.definition),
            query: query,
            limit: room
        )
        let byName = Dictionary(candidates.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var selected = requiredTools + ranked.compactMap { byName[$0.name] }
        let rankedNames = selected.map(\.name)

        // Fill only when ranking had nothing to say.
        //
        // The selector returns matches above a score floor, so every
        // tool a fill adds scored *zero* against the query — it is
        // included on the strength of nothing at all. That is the right
        // hedge when ranking failed outright, and the wrong one when it
        // succeeded.
        //
        // This used to fill unconditionally, on the reasoning that a
        // tool costing nothing in spare budget could only help. The
        // field disproved it: "Check my fasting status" ranked the
        // fasting tool correctly, then filled eight more to the cap in
        // arbitrary array order, and the model opened the turn by
        // calling `remember_fact` on a question — six seconds of an
        // eleven-second time-to-first-token spent on a tool no
        // reasonable ranking would have offered.
        //
        // So spare budget is not free. Unrelated tools cost accuracy
        // and latency on a small model whether or not their tokens fit,
        // and a half-empty context window is only a problem if the tool
        // the user needed is the part that's missing.
        guard selected.count == requiredTools.count else {
            return (
                Self.fitting(
                    selected,
                    required: requiredTools,
                    ceiling: ceiling,
                    cost: { self.tokenCounter.count(tool: $0.definition) }
                ),
                rankedNames
            )
        }

        // Nothing scored. How much to read into that depends on the
        // ranker, so the caller decides — see `unrankedFillLimit`.
        let fillCeiling = self.unrankedFillLimit ?? maxTools
        guard fillCeiling > 0 else {
            return (selected, rankedNames)
        }
        var chosen = Set(selected.map(\.name))
        var spent = selected.reduce(0) { $0 + self.tokenCounter.count(tool: $1.definition) }

        var filled = 0
        for tool in candidates where !chosen.contains(tool.name) {
            guard selected.count < maxTools, filled < fillCeiling else {
                break
            }
            let cost = self.tokenCounter.count(tool: tool.definition)
            guard spent + cost <= ceiling else {
                continue
            }
            selected.append(tool)
            chosen.insert(tool.name)
            spent += cost
            filled += 1
        }

        return (selected, rankedNames)
    }

    /// Cap each tool result at `limit` tokens, returning the bounded
    /// messages and how many were cut.
    ///
    /// Truncation is marked rather than silent. A model handed a
    /// fragment it believes is complete will answer confidently from
    /// half a document; one told the result was cut can say so, or call
    /// again more narrowly.
    private func boundToolResults(
        _ messages: [Message],
        limit: Int
    ) -> (messages: [Message], truncated: Int) {
        guard limit > 0 else {
            return (messages, 0)
        }
        var truncated = 0
        let bounded = messages.map { message -> Message in
            guard message.role == .tool else {
                return message
            }
            let text = message.textContent
            guard self.tokenCounter.count(text: text) > limit,
                  let shortened = self.truncate(text, to: limit) else {
                return message
            }
            truncated += 1
            return .tool(callId: message.toolCallId ?? "", text: shortened)
        }
        return (bounded, truncated)
    }

    /// Longest prefix of `text` that fits in `limit` tokens once the
    /// marker is included.
    ///
    /// Binary search over the counter rather than a characters-per-token
    /// assumption, so a counter backed by a real tokenizer stays correct
    /// where a ratio would not.
    private func truncate(_ text: String, to limit: Int) -> String? {
        let marker = "\n\n… [truncated to fit the context window]"
        let markerCost = self.tokenCounter.count(text: marker)
        let budget = limit - markerCost
        guard budget > 0 else {
            return marker
        }

        let characters = Array(text)
        var low = 0
        var high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            if self.tokenCounter.count(text: String(characters[0..<middle])) <= budget {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return String(characters[0..<low]) + marker
    }

    /// Trim oldest history until it fits, preserving system messages.
    private func windowMessages(
        _ messages: [Message],
        limit: Int
    ) -> WindowedHistory {
        // Whole messages, not just their text: an assistant turn that
        // only requests a tool has no body and is not free.
        let cost = { (message: Message) in self.tokenCounter.count(message: message) }
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
