import Foundation
import Logging

// MARK: - AgentApprovalSink

/// Per-run mailbox the `propose_action` tool writes a pending
/// `AgentProposal` into. The runtime reads it after the agent's stream
/// finishes to decide whether to park the run as `awaitingApproval`.
///
/// `@unchecked Sendable`: a single `NSLock` guards the box so the tool
/// (which fires off-main inside the agent loop) and the runtime (which
/// reads on completion) can't race.
final class AgentApprovalSink: @unchecked Sendable {
    // MARK: Lifecycle

    init() { }

    // MARK: Internal

    /// The proposal recorded during the current turn, if any.
    var proposal: AgentProposal? {
        self.lock.withLock { self.stored }
    }

    /// Read the current rejection count. Used by `ProposeTool`
    /// to decide whether to keep nudging the model with a
    /// detailed reason or send a hard-stop message.
    var rejectionCount: Int {
        self.lock.withLock { self.rejectionCountStorage }
    }

    /// Record a proposal. Last write wins within a turn. Also
    /// implicitly closes the rejection-retry budget — a
    /// successful propose ends the validation loop.
    func record(_ proposal: AgentProposal) {
        Self.logger.debug(
            "sink.record kind=\(proposal.kind) title=\(proposal.title) payload=\(proposal.payload)"
        )
        self.lock.withLock {
            self.stored = proposal
            self.rejectionCountStorage = 0
        }
    }

    /// Bump the rejection counter — called when `ProposeTool`
    /// finds the payload invalid. Used to enforce a hard cap on
    /// retry attempts (small models tend to spam the same
    /// malformed payload back rather than self-correct, which
    /// would otherwise blow the context window).
    func recordRejection() {
        self.lock.withLock { self.rejectionCountStorage += 1 }
    }

    /// Clear before a fresh turn / resume.
    func reset() {
        Self.logger.debug("sink.reset (was=\(self.stored?.kind ?? "nil"))")
        self.lock.withLock {
            self.stored = nil
            self.rejectionCountStorage = 0
        }
    }

    // MARK: Private

    /// `swift-log` Logger — replaces the old `print("[AGENT] ...")`
    /// debug spam. Same label namespace Aria's core logger uses,
    /// suffixed `agentkit.approval` so hosts can selectively
    /// quiet it via `LoggingSystem.bootstrap`.
    private static let logger = Logger(label: "com.aria.agentkit.approval")

    private let lock = NSLock()
    private var stored: AgentProposal?
    private var rejectionCountStorage: Int = 0
}
