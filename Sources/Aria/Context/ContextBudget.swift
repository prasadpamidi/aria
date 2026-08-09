import Foundation

// MARK: - ContextBudget

/// How much room a single provider call has, and how it may be spent.
///
/// The budget exists because nothing in the agent loop previously knew
/// the answer. `ProviderCapabilities.maxContextTokens` was populated by
/// every provider and read by none, and the only component that
/// *sounded* like it budgeted context — `HistoryWindowMiddleware` —
/// runs before the system prompt is prepended and never sees tool
/// definitions at all. It could inspect a few hundred tokens of history
/// while several thousand tokens of tool schemas went to the model
/// unmeasured.
///
/// A budget is therefore only meaningful alongside a component that can
/// see the whole request. That component is `ContextAssembler`, which
/// runs at step assembly where the system prompt, the tools, and the
/// messages are simultaneously in scope.
public struct ContextBudget: Sendable, Equatable {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - total: The window the model can *actually* use, which is not
    ///     always what it advertises. On-device models are the sharp
    ///     case: an MLX `config.json` may claim a 128k context while KV
    ///     cache memory bounds the practical limit far lower. Prefer
    ///     `ProviderCapabilities.usableContextTokens` over
    ///     `maxContextTokens` when deriving this.
    ///   - reservedForOutput: Held back so the model has room to reply.
    ///     A budget spent entirely on input leaves nothing to generate
    ///     into.
    ///   - maxTools: Cap on tool definitions sent per call. `nil` means
    ///     unbounded.
    ///
    ///     Deliberately a plain `Int`, not a capability tier. Model
    ///     reliability tiers live in `AriaMLX`, and core must not depend
    ///     on them — so consumers map their own notion of capability
    ///     onto a number here.
    ///   - maxToolShare: Ceiling on the fraction of `available` that
    ///     tool definitions may occupy.
    ///
    ///     Ranking decides *order*; this decides *how many*. Without
    ///     it, a selector that finds one lexical match sends one tool
    ///     and leaves the rest of the window empty — the tools it
    ///     discarded cost nothing to include and might have been the
    ///     ones needed. Filtering should be driven by pressure on the
    ///     budget, not applied unconditionally.
    ///   - maxToolResultShare: Ceiling on the fraction of `available`
    ///     that any *single* tool result may occupy.
    ///
    ///     Windowing drops whole messages oldest-first, which is the
    ///     right shape for conversation and no defence at all against a
    ///     tool that returns something enormous. The newest messages are
    ///     never dropped — the model must have something to respond
    ///     to — so three large results in a row cannot be trimmed by
    ///     dropping anything, and the request goes out over budget.
    ///
    ///     Observed: a `load_skill` tool returning full Markdown bodies
    ///     was called three times after an unrelated tool failed, and
    ///     the turn died inside the provider with a token-generation
    ///     error rather than anywhere the budget could see. Capping each
    ///     result makes the overflow structurally impossible instead of
    ///     merely unlikely.
    public init(
        total: Int,
        reservedForOutput: Int = 512,
        maxTools: Int? = nil,
        maxToolShare: Double = 0.4,
        maxToolResultShare: Double = 0.25,
        safetyMargin: Double = 0.1
    ) {
        self.total = max(0, total)
        self.reservedForOutput = max(0, min(reservedForOutput, self.total))
        self.maxTools = maxTools.map { max(0, $0) }
        self.maxToolShare = min(max(0, maxToolShare), 1)
        self.maxToolResultShare = min(max(0, maxToolResultShare), 1)
        self.safetyMargin = min(max(0, safetyMargin), 0.5)
    }

    // MARK: Public

    /// Usable context window in tokens.
    public let total: Int

    /// Tokens withheld from input so the model can generate a reply.
    public let reservedForOutput: Int

    /// Maximum tool definitions per call. `nil` disables the cap.
    public let maxTools: Int?

    /// Fraction of `available` that tool definitions may occupy.
    public let maxToolShare: Double

    /// Fraction of `available` any single tool result may occupy.
    public let maxToolResultShare: Double

    /// Fraction of the window held back to absorb estimator error.
    ///
    /// Token counts here are estimates — core carries no vendor
    /// tokenizer — and the estimate is not symmetric in consequence.
    /// Over-counting trims a little history. Under-counting is fatal on
    /// a provider that refuses rather than truncates: FoundationModels
    /// rejected a request at 4,110 tokens against a 4,096 ceiling that
    /// the assembler believed it had stayed under, and the whole turn
    /// was lost.
    ///
    /// A margin does not make the estimate right, and is not a
    /// substitute for counting the things that were being missed
    /// outright. It buys the room for the estimate to be somewhat wrong
    /// in the direction it is known to err.
    public let safetyMargin: Double

    /// Token ceiling for tool definitions.
    public var toolTokenLimit: Int {
        Int(Double(self.available) * self.maxToolShare)
    }

    /// Token ceiling for one tool result. Results above this are
    /// truncated with a marker rather than dropped: the model needs to
    /// know it is reading a fragment, and the beginning of a result is
    /// usually the part that matters.
    public var toolResultTokenLimit: Int {
        Int(Double(self.available) * self.maxToolResultShare)
    }

    /// Tokens the assembler may spend on input.
    public var available: Int {
        let usable = self.total - self.reservedForOutput
        return max(0, usable - Int(Double(usable) * self.safetyMargin))
    }
}

// MARK: - ContextAllocation

/// What the assembler actually spent, and what it had to drop.
///
/// Emitted alongside every assembled context so the cost of a turn is
/// inspectable rather than inferred. The investigation that motivated
/// this type required reading source across three repositories to
/// answer "why is this prompt 5,474 tokens?" — a question this struct
/// answers directly.
public struct ContextAllocation: Sendable, Equatable, Codable {
    // MARK: Lifecycle

    public init(
        systemPromptTokens: Int = 0,
        toolTokens: Int = 0,
        memoryTokens: Int = 0,
        historyTokens: Int = 0,
        budgetAvailable: Int = 0,
        toolsOffered: Int = 0,
        toolsSelected: Int = 0,
        selectedToolNames: [String] = [],
        offeredToolNames: [String] = [],
        rankedToolNames: [String] = [],
        maxTools: Int? = nil,
        toolTokenLimit: Int = 0,
        messagesDropped: Int = 0,
        memoriesDropped: Int = 0,
        toolResultsTruncated: Int = 0
    ) {
        self.systemPromptTokens = systemPromptTokens
        self.toolTokens = toolTokens
        self.memoryTokens = memoryTokens
        self.historyTokens = historyTokens
        self.budgetAvailable = budgetAvailable
        self.toolsOffered = toolsOffered
        self.toolsSelected = toolsSelected
        self.selectedToolNames = selectedToolNames
        self.offeredToolNames = offeredToolNames
        self.rankedToolNames = rankedToolNames
        self.maxTools = maxTools
        self.toolTokenLimit = toolTokenLimit
        self.messagesDropped = messagesDropped
        self.memoriesDropped = memoriesDropped
        self.toolResultsTruncated = toolResultsTruncated
    }

    // MARK: Public

    public let systemPromptTokens: Int
    public let toolTokens: Int
    public let memoryTokens: Int
    public let historyTokens: Int

    /// The ceiling these numbers were allocated against.
    public let budgetAvailable: Int

    /// Tools the agent had registered, before selection.
    public let toolsOffered: Int

    /// Tools that survived selection and were sent.
    public let toolsSelected: Int

    /// Names of the tools that survived, in the order they were sent.
    ///
    /// Counts alone say a surface was trimmed; names say *what to*.
    /// The question a developer actually has when a model fails to act
    /// is "was the tool I expected even offered?", and only the list
    /// answers it.
    public let selectedToolNames: [String]
    /// Every tool the selector could have chosen from.
    ///
    /// `toolsOffered` was a count, which is enough to notice a surprise
    /// and never enough to explain one. Asked for a weather summary
    /// with a weather server connected, a run sent exactly one tool
    /// (`load_skill`) out of twenty-eight — and the count could not
    /// distinguish "the ranker buried the weather tools" from "the
    /// weather tools were never candidates", which have nothing in
    /// common except the symptom.
    public let offeredToolNames: [String]
    /// What ranking chose, *before* the token ceiling trimmed it.
    ///
    /// The distinction is the whole diagnosis. If this is empty the
    /// ranker found nothing and the query or the corpus is the
    /// problem; if it is full and `selectedToolNames` is short, the
    /// budget did the cutting. Both end with a tool missing from the
    /// request and there is otherwise no way to tell them apart.
    public let rankedToolNames: [String]
    /// Count cap in force for this turn.
    public let maxTools: Int?
    /// Token ceiling in force for this turn.
    public let toolTokenLimit: Int

    /// History messages dropped to fit.
    public let messagesDropped: Int

    /// Recalled memories dropped to fit.
    public let memoriesDropped: Int

    /// Tool results cut down to fit their per-result ceiling.
    ///
    /// Distinct from `messagesDropped`: a dropped message is gone, a
    /// truncated one is still there and incomplete. A model reasoning
    /// from a fragment fails in a different and more confusing way than
    /// one reasoning from less history, so the two are worth telling
    /// apart in a trace.
    public let toolResultsTruncated: Int

    /// Total input tokens the assembler believes it produced.
    public var totalTokens: Int {
        self.systemPromptTokens + self.toolTokens + self.memoryTokens + self.historyTokens
    }

    /// `true` when the assembler could not fit everything it was asked
    /// to fit. Useful as a one-line health signal in diagnostics.
    public var didTruncate: Bool {
        self.messagesDropped > 0
            || self.memoriesDropped > 0
            || self.toolResultsTruncated > 0
            || self.toolsSelected < self.toolsOffered
    }
}
