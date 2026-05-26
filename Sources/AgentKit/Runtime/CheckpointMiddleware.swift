import Aria
import Foundation

// MARK: - CheckpointMiddleware

/// Persists the agent's `AgentState` after each completed step so a run
/// can survive app suspension / kill. Writes to the same
/// `Checkpointer` AriaApple's `GRDBStorage` already vends
/// (`storage.checkpointer`) and mirrors the step + checkpoint id onto
/// the run's `AgentRunRecord` so the Active Runs surface stays current.
///
/// Granularity is the step boundary (`afterStep` fires once the
/// provider round + any tool results have landed). An in-flight
/// partial step is intentionally lost on kill — resume re-enters from
/// the last completed step via history replay, and the HITL design
/// keeps side effects out of the loop so a re-run can't double-fire.
///
/// `@unchecked Sendable`: all stored state is immutable and Sendable
/// (the `Checkpointer` existential, the file-backed `AgentRunStore`,
/// and a `@Sendable` callback), so no lock is required.
final class CheckpointMiddleware: AgentMiddleware, @unchecked Sendable {
    // MARK: Lifecycle

    init(
        checkpointer: any Checkpointer,
        runID: UUID,
        runStore: AgentRunStore,
        onCheckpoint: @escaping @Sendable (_ checkpointID: String, _ step: Int) -> Void
    ) {
        self.checkpointer = checkpointer
        self.runID = runID
        self.runStore = runStore
        self.onCheckpoint = onCheckpoint
    }

    // MARK: Internal

    func afterStep(_ state: AgentState) async throws -> AgentState {
        let data = try JSONEncoder().encode(state)
        let checkpoint = Checkpoint(
            threadId: state.threadId,
            state: data,
            metadata: [
                "runID": .string(self.runID.uuidString),
                "step": .integer(Int64(state.stepCount)),
            ]
        )
        try await self.checkpointer.put(checkpoint, threadId: state.threadId)
        // Mirror progress onto the durable run record. Leaves `status`
        // untouched — the run is still actively running here; status
        // transitions (paused / awaitingApproval / completed) are the
        // runtime's job.
        _ = try? self.runStore.update(id: self.runID) { record in
            record.currentStep = state.stepCount
            record.lastCheckpointID = checkpoint.id
        }
        self.onCheckpoint(checkpoint.id, state.stepCount)
        return state
    }

    // MARK: Private

    private let checkpointer: any Checkpointer
    private let runID: UUID
    private let runStore: AgentRunStore
    private let onCheckpoint: @Sendable (String, Int) -> Void
}
