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
    public init(
        total: Int,
        reservedForOutput: Int = 512,
        maxTools: Int? = nil
    ) {
        self.total = max(0, total)
        self.reservedForOutput = max(0, min(reservedForOutput, self.total))
        self.maxTools = maxTools.map { max(0, $0) }
    }

    // MARK: Public

    /// Usable context window in tokens.
    public let total: Int

    /// Tokens withheld from input so the model can generate a reply.
    public let reservedForOutput: Int

    /// Maximum tool definitions per call. `nil` disables the cap.
    public let maxTools: Int?

    /// Tokens the assembler may spend on input.
    public var available: Int {
        self.total - self.reservedForOutput
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
        messagesDropped: Int = 0,
        memoriesDropped: Int = 0
    ) {
        self.systemPromptTokens = systemPromptTokens
        self.toolTokens = toolTokens
        self.memoryTokens = memoryTokens
        self.historyTokens = historyTokens
        self.budgetAvailable = budgetAvailable
        self.toolsOffered = toolsOffered
        self.toolsSelected = toolsSelected
        self.messagesDropped = messagesDropped
        self.memoriesDropped = memoriesDropped
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

    /// History messages dropped to fit.
    public let messagesDropped: Int

    /// Recalled memories dropped to fit.
    public let memoriesDropped: Int

    /// Total input tokens the assembler believes it produced.
    public var totalTokens: Int {
        self.systemPromptTokens + self.toolTokens + self.memoryTokens + self.historyTokens
    }

    /// `true` when the assembler could not fit everything it was asked
    /// to fit. Useful as a one-line health signal in diagnostics.
    public var didTruncate: Bool {
        self.messagesDropped > 0 || self.memoriesDropped > 0 || self.toolsSelected < self.toolsOffered
    }
}
