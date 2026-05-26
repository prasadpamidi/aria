import Aria
import Foundation

// MARK: - AgentRunEvent

/// The avyra-level event stream a run surfaces to the UI / Live
/// Activity. Maps aria's `AgentEvent` 1:1 where it can and adds the
/// run-lifecycle events aria doesn't model: checkpoint writes,
/// approval parking, pause, and a terminal `finished`/`failed` that
/// folds in the accumulated output.
public enum AgentRunEvent: Sendable {
    case runStarted(runID: UUID)
    case stepStart(Int)
    case assistantStart
    case textDelta(String)
    case toolCallRequested(ToolCall)
    case toolExecutionStart(callId: String)
    case toolExecutionEnd(callId: String, result: ToolExecutionResult)
    case stepEnd(Int)
    /// A checkpoint landed (from `CheckpointMiddleware`, off-loop).
    case checkpointSaved(checkpointID: String, step: Int)
    /// The agent proposed a side-effecting action and parked, waiting
    /// for the user's approve/reject decision.
    case awaitingApproval(AgentProposal)
    /// The run was paused (app backgrounded / explicit pause) with a
    /// resumable checkpoint.
    case paused(runID: UUID, lastCheckpointID: String?)
    /// Terminal success — carries the finish reason and the
    /// accumulated assistant text.
    case finished(reason: FinishReason, output: String)
    /// Terminal failure.
    case failed(String)
}
