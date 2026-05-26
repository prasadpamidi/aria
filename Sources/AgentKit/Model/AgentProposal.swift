import Aria
import Foundation

// MARK: - ApprovalPolicy

/// Human-in-the-loop posture for an agent.
///
/// The implementation uses a **propose-then-host-executes** pattern
/// rather than interrupting a tool mid-call: a trust-critical agent
/// is compiled WITHOUT any side-effecting tool (e.g. no `send_email`)
/// and instead gets a safe `propose_action` tool. The agent proposes;
/// the host runs the real side effect only after the user approves.
/// This is re-run safe (no side effect ever fires inside the agent
/// loop) and a stronger guarantee than a cancellable call.
public enum ApprovalPolicy: Codable, Sendable, Equatable {
    /// Agent acts directly; no approval gate. Appropriate for
    /// read-only agents (briefings, research).
    case autonomous
    /// Listed action `kind`s must be proposed and host-executed on
    /// approval. The compiler keeps the matching side-effecting
    /// tools out of the agent's surface and adds `propose_action`.
    case proposeThenConfirm(actions: Set<String>)
}

// MARK: - AgentProposal

/// A structured action an agent wants the user to approve before it
/// happens. Produced by the `propose_action` tool, parked on the
/// `AgentRunRecord`, and surfaced in the run UI / Live Activity /
/// notification as an approve-or-reject card.
public struct AgentProposal: Codable, Identifiable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        id: UUID = UUID(),
        kind: String,
        title: String,
        detail: String = "",
        payload: JSONValue
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.payload = payload
    }

    // MARK: Public

    public let id: UUID
    /// Action discriminator, e.g. `"send_email"`, `"create_event"`.
    /// Matches the entries in `ApprovalPolicy.proposeThenConfirm`.
    public let kind: String
    /// Short, human-readable headline for the approval card.
    public let title: String
    /// Optional longer body (e.g. the drafted email text).
    public let detail: String
    /// Structured arguments the host passes to the capability/MCP
    /// tool when the user approves.
    public let payload: JSONValue
}

// MARK: - ApprovalResolution

/// The user's decision on a pending `AgentProposal`, handed back to
/// `AgentRuntime.resume(runID:approval:)`.
public enum ApprovalResolution: Sendable, Equatable {
    case approve
    case reject
    /// Approve with an edited payload (user tweaked the draft before
    /// sending). Carries the replacement arguments.
    case edit(JSONValue)
}
