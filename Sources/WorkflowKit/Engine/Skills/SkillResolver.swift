import Foundation

// MARK: - WorkflowSkillResolver

/// Closure the workflow compiler uses to expand skill IDs into
/// the markdown blocks an LLM step needs.
///
/// Workflow LLM steps are single-shot — they don't run an agent
/// loop, so the `load_skill` tool the chat path uses can't fire
/// inside them. The compiler instead inlines every requested
/// skill's description + body directly into the step's prompt,
/// keeping the activation strategy simple and predictable.
///
/// The closure is async because the app-side resolver typically
/// reads the body off disk through `SkillProvider.loadBody`. The
/// resolver is `Sendable` so the compiler can hand it across the
/// `@MainActor`-isolated boundary that the StateGraph node's
/// executor sits on.
public typealias WorkflowSkillResolver = @Sendable (Set<UUID>) async -> WorkflowSkillBlock

// MARK: - WorkflowSkillBlock

/// Result of expanding a skill-id set into prompt text. Empty
/// when the input set was empty or every id failed to resolve;
/// callers can append unconditionally without polluting the
/// prompt in the empty case.
public struct WorkflowSkillBlock: Sendable, Equatable {
    // MARK: Lifecycle

    public init(text: String, resolvedSkillIDs: Set<UUID>) {
        self.text = text
        self.resolvedSkillIDs = resolvedSkillIDs
    }

    // MARK: Public

    public static let empty = WorkflowSkillBlock(text: "", resolvedSkillIDs: [])

    /// Pre-formatted markdown block ready to splice into a
    /// system prompt. Includes inline bodies for every skill —
    /// workflows don't have a tool loop, so progressive
    /// disclosure isn't an option here.
    public let text: String

    /// IDs the resolver actually returned content for. The
    /// requested set minus any that 404'd. Surfaced so the
    /// editor can flag stale references after a skill delete.
    public let resolvedSkillIDs: Set<UUID>
}

// MARK: - WorkflowSkillSet

/// Helper for computing the effective skill set for one LLM
/// step: union the workflow's `enabledSkillIDs` with the step's
/// `extraSkillIDs`, then subtract the step's `disabledSkillIDs`.
/// Pulled out so the compiler + tests share the same arithmetic.
public enum WorkflowSkillSet {
    public static func effective(
        workflow: Workflow,
        step: LLMStep
    ) -> Set<UUID> {
        let base = workflow.enabledSkillIDs.union(step.extraSkillIDs)
        return base.subtracting(step.disabledSkillIDs)
    }
}
