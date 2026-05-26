import Foundation

// MARK: - AgentRunRecord

/// Durable bookkeeping for a single agent run. Persisted by
/// `AgentRunStore` so the app can list resumable runs, drive the
/// Live Activity, and route approvals — independent of the in-memory
/// `AsyncThrowingStream` that carries live events.
///
/// `id` doubles as the run identifier and the seed for the aria
/// `threadId`, so checkpoints, chat history, and this record all key
/// off the same run.
public struct AgentRunRecord: Codable, Identifiable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        id: UUID = UUID(),
        agentID: UUID,
        threadId: String,
        status: RunStatus = .running,
        currentStep: Int = 0,
        lastCheckpointID: String? = nil,
        pendingProposal: AgentProposal? = nil,
        inputSummary: String = "",
        outputSummary: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.agentID = agentID
        self.threadId = threadId
        self.status = status
        self.currentStep = currentStep
        self.lastCheckpointID = lastCheckpointID
        self.pendingProposal = pendingProposal
        self.inputSummary = inputSummary
        self.outputSummary = outputSummary
        self.createdAt = Self.roundedToMillisecond(createdAt)
        self.updatedAt = Self.roundedToMillisecond(updatedAt)
    }

    // MARK: Public

    /// Lifecycle states a run moves through. `paused` and
    /// `awaitingApproval` are the resumable states the
    /// "Active Runs" surface lists.
    public enum RunStatus: String, Codable, Sendable {
        case running
        case paused
        case awaitingApproval
        case completed
        case failed
    }

    public let id: UUID
    public let agentID: UUID
    public let threadId: String
    public var status: RunStatus
    public var currentStep: Int
    /// Latest checkpoint written by `CheckpointMiddleware`; the
    /// audit/scratchpad anchor for a resume (history replay is the
    /// load-bearing resume mechanism).
    public var lastCheckpointID: String?
    /// Set when `status == .awaitingApproval`. Cleared on resolution.
    public var pendingProposal: AgentProposal?
    public var inputSummary: String
    public var outputSummary: String?
    public var createdAt: Date
    public var updatedAt: Date

    /// True when the run can be picked back up from the Active Runs
    /// list / a notification / the Live Activity.
    public var isResumable: Bool {
        switch self.status {
        case .paused, .awaitingApproval: true
        case .running, .completed, .failed: false
        }
    }

    // MARK: Private

    private static func roundedToMillisecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}

// MARK: - AgentRunRecord factory

extension AgentRunRecord {
    /// Mint a fresh run for `agentID`. Pass `threadId` to attach
    /// this run to an existing conversation (so the agent sees
    /// prior turns via `HistoryMiddleware` on the same thread).
    /// Omitting the parameter mints a new run-scoped thread —
    /// the historical default, used when a brand-new screen
    /// starts a brand-new conversation.
    public static func start(
        agentID: UUID,
        inputSummary: String,
        threadId: String? = nil
    ) -> AgentRunRecord {
        let runID = UUID()
        return AgentRunRecord(
            id: runID,
            agentID: agentID,
            threadId: threadId ?? "agent-run-\(runID.uuidString)",
            status: .running,
            inputSummary: inputSummary
        )
    }
}
