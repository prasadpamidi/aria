import Foundation

// MARK: - HistoryWindowMiddleware

/// Caps the message history passed to the provider on every step,
/// trimming oldest user/assistant turns until both a turn-count limit
/// and a token-budget limit are satisfied.
///
/// **What this is for.** Persistent `ChatHistory` (loaded by
/// `HistoryMiddleware` on `beforeRun`) grows unbounded over the
/// lifetime of a thread. Without a cap, every turn re-sends the entire
/// transcript to the provider — eventually overflowing the model's
/// context window, burning tokens, and slowing first-token latency.
/// This middleware runs in `beforeStep` (after `HistoryMiddleware` has
/// loaded the history) and *windows* the state's messages down to a
/// bounded slice before the provider sees them.
///
/// **What it preserves.** System messages always survive — they carry
/// the agent's instructions and dropping them would change the model's
/// behavior. Tool messages stay paired with the assistant turn that
/// emitted the tool call (dropping a tool result without its
/// originating call leaves the model confused). The most recent
/// assistant + user turns always survive even if both caps want to
/// drop them — the provider needs *something* to respond to.
///
/// **What it does not do.** No I/O. No persistence side-effects.
/// `HistoryMiddleware` keeps writing every turn to storage (so future
/// runs can re-load the full transcript); this middleware only shapes
/// what gets sent on the wire *this* step. Pair with
/// `HistoryRetentionPolicy` to also bound the disk side.
///
/// **Token counting.** Default is a deliberately conservative
/// 4-chars-per-token heuristic — good enough to keep most prompts
/// under the budget without pulling in a vendor-specific tokenizer.
/// Callers who want exact counts can inject `tokenCounter` (e.g.
/// wrapping tiktoken). The middleware never calls a network; the
/// counter is purely local.
///
/// **Ordering.** Wire this *after* `HistoryMiddleware` (so the loaded
/// history is in `state.messages` when this middleware runs) and
/// *before* `RAGMiddleware` (so recalled facts don't get budgeted out
/// — they're typically prepended as a fresh system message, which is
/// preserved).
public struct HistoryWindowMiddleware: AgentMiddleware {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - maxTurns: Maximum number of non-system messages to keep.
    ///     Counts user/assistant/tool messages; system messages are
    ///     always preserved on top. `nil` disables the turn cap.
    ///   - maxTokens: Maximum total token budget across ALL messages
    ///     (system + history). When exceeded, oldest non-system
    ///     messages drop until the budget fits. `nil` disables the
    ///     token cap.
    ///   - tokenCounter: Optional per-message token counter. Defaults
    ///     to `max(1, message.textContent.count / 4)` — a rough
    ///     average across English text and code. Inject a real
    ///     tokenizer when you need exact accounting.
    ///
    /// At least one of `maxTurns` or `maxTokens` should be non-nil;
    /// otherwise the middleware is a no-op.
    public init(
        maxTurns: Int? = nil,
        maxTokens: Int? = nil,
        tokenCounter: (@Sendable (Message) -> Int)? = nil
    ) {
        self.maxTurns = maxTurns
        self.maxTokens = maxTokens
        self.tokenCounter = tokenCounter ?? Self.defaultTokenCounter
    }

    // MARK: Public

    public func beforeStep(_ state: AgentState) async throws -> AgentState {
        let windowed = Self.window(
            messages: state.messages,
            maxTurns: self.maxTurns,
            maxTokens: self.maxTokens,
            tokenCounter: self.tokenCounter
        )
        if windowed.count == state.messages.count {
            return state
        }
        var newState = state
        newState.messages = windowed
        return newState
    }

    // MARK: Internal

    /// Pure trimming logic — extracted so unit tests can drive it
    /// without standing up an Agent.
    static func window(
        messages: [Message],
        maxTurns: Int?,
        maxTokens: Int?,
        tokenCounter: (Message) -> Int
    ) -> [Message] {
        guard maxTurns != nil || maxTokens != nil else {
            return messages
        }
        // Partition: system messages (always kept on top, in original
        // order) vs non-system (the windowable tail).
        var systems: [Message] = []
        var tail: [Message] = []
        for message in messages {
            if message.role == .system {
                systems.append(message)
            } else {
                tail.append(message)
            }
        }

        // Apply the turn cap to the tail first — cheap to compute.
        if let maxTurns, tail.count > maxTurns {
            // Keep the last `maxTurns` non-system messages.
            tail = Array(tail.suffix(maxTurns))
        }

        // Then apply the token cap. Drop oldest tail messages until
        // (systems + tail) fits the budget. Always keep at least one
        // tail message so the provider has something to respond to.
        if let maxTokens {
            let systemTokens = systems.reduce(0) { $0 + tokenCounter($1) }
            var tailTokens = tail.reduce(0) { $0 + tokenCounter($1) }
            while systemTokens + tailTokens > maxTokens, tail.count > 1 {
                let dropped = tail.removeFirst()
                tailTokens -= tokenCounter(dropped)
            }
        }

        return systems + tail
    }

    // MARK: Private

    /// 4-chars-per-token rough heuristic. Good enough for budgeting;
    /// callers needing exact counts inject a vendor tokenizer.
    private static let defaultTokenCounter: @Sendable (Message) -> Int = { message in
        max(1, message.textContent.count / 4)
    }

    private let maxTurns: Int?
    private let maxTokens: Int?
    private let tokenCounter: @Sendable (Message) -> Int
}
