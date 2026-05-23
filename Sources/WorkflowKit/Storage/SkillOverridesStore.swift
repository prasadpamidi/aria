import Foundation
import Observation

// MARK: - SkillOverridesStore

/// Per-scope skill overrides. Skills are globally enabled in the
/// host app's Settings, but a user often wants to *override* that
/// for a single scope (a chat thread, a workflow run, an editor
/// session, etc.). The scope is identified by an opaque string
/// key so the same store backs both per-thread and per-workflow
/// overrides without needing a second type.
///
/// Two override flavours, stored asymmetrically:
///
///   * **`disabled`** — skills the user toggled off for this
///     scope. Subtracted from the effective set.
///   * **`extra`**    — skills the user manually attached for
///     this scope. Added to the effective set even if the skill
///     is globally disabled (an explicit "give me this once"
///     gesture).
///
/// Persisted to a single JSON file at `fileURL` so overrides
/// survive across launches. Typically a process-wide singleton;
/// SwiftUI views read and write via `@Bindable`.
///
/// Effective set computation:
///
/// ```
/// effective = (globalEnabledIDs ∪ extra[scope]) - disabled[scope]
/// ```
@MainActor
@Observable
public final class SkillOverridesStore {
    // MARK: Lifecycle

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.overrides = Self.read(from: fileURL)
    }

    // MARK: Public

    /// Effective skill IDs for a given scope, given the
    /// currently globally-enabled set. Caller passes
    /// `globalEnabledIDs` (typically
    /// `provider.enabledSkills().map(\.id)`) so the store stays
    /// decoupled from `SkillProvider`.
    public func effectiveSkillIDs(
        for scope: String,
        globalEnabledIDs: Set<UUID>
    ) -> Set<UUID> {
        let entry = self.overrides[scope] ?? .init()
        return globalEnabledIDs.union(entry.extra).subtracting(entry.disabled)
    }

    /// User toggled the skill on or off for this scope via the
    /// chip rail. Stored asymmetrically: turning OFF a globally-
    /// enabled skill writes to `disabled`; turning ON a globally-
    /// disabled skill writes to `extra`. Toggling back returns
    /// to the global default rather than persisting redundant
    /// state.
    public func setEnabled(
        _ enabled: Bool,
        skillID: UUID,
        for scope: String,
        globallyEnabled: Bool
    ) {
        var entry = self.overrides[scope] ?? .init()
        defer {
            if entry.isEmpty {
                self.overrides.removeValue(forKey: scope)
            } else {
                self.overrides[scope] = entry
            }
            self.persist()
        }
        switch (enabled, globallyEnabled) {
        case (true, true):
            // Reaching the global default — clear any disable.
            entry.disabled.remove(skillID)
            entry.extra.remove(skillID)
        case (true, false):
            // Explicit per-scope attach.
            entry.disabled.remove(skillID)
            entry.extra.insert(skillID)
        case (false, true):
            // Explicit per-scope disable of a globally-enabled skill.
            entry.disabled.insert(skillID)
            entry.extra.remove(skillID)
        case (false, false):
            // Already off globally — clear any redundant override.
            entry.disabled.remove(skillID)
            entry.extra.remove(skillID)
        }
    }

    /// True when the user has touched any override on this
    /// scope — used to differentiate the rail's resting empty
    /// state from "intentionally cleared."
    public func hasOverrides(for scope: String) -> Bool {
        guard let entry = self.overrides[scope] else {
            return false
        }
        return !entry.isEmpty
    }

    // MARK: Private

    private struct Entry: Codable, Equatable {
        var disabled: Set<UUID> = []
        var extra: Set<UUID> = []

        var isEmpty: Bool {
            self.disabled.isEmpty && self.extra.isEmpty
        }
    }

    private let fileURL: URL
    private var overrides: [String: Entry]

    private static func read(from url: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: url) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private func persist() {
        do {
            let parent = self.fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(self.overrides)
            try data.write(to: self.fileURL, options: .atomic)
        } catch {
            // Persistence failures shouldn't break the host UI —
            // overrides will replay from in-memory state for the
            // rest of the session and a future write will retry.
            print("[WorkflowKit/SkillOverrides] persist failed: \(error)")
        }
    }
}
