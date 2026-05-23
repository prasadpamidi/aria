import Foundation

// MARK: - SkillPromptBuilder

/// Builds the system-prompt augmentation that advertises the
/// enabled skills. Two sections:
///
///   1. **Inline bodies** — for skills with `alwaysInline = true`
///      we paste the full body so the model has it without a
///      round-trip.
///   2. **Catalogue** — one line per non-inline skill listing
///      `name` and `description` so the model knows when to
///      call `load_skill(name:)`.
///
/// Returns an empty string when no skills are enabled — callers
/// can append unconditionally without polluting the prompt.
///
/// Pure Foundation; no platform-specific dependencies. Apps wire
/// the returned string into whichever provider stack they use
/// (FoundationModels, MLX, OpenAI, etc.) — see the host app's
/// `LoadSkillTool` for a reference integration with Apple's
/// FoundationModels tool surface.
@MainActor
public enum SkillPromptBuilder {
    // MARK: Public

    public static func systemPromptBlock(
        provider: SkillProvider,
        allowedSkillIDs: Set<UUID>? = nil
    ) -> String {
        let baseline = provider.enabledSkills()
        let skills: [Skill] =
            if let allowed = allowedSkillIDs {
                // Honour per-scope overrides: keep globally
                // enabled ∩ allowed, then add any extras the user
                // attached that aren't in the global set.
                Self.resolve(allowed: allowed, baseline: baseline, provider: provider)
            } else {
                baseline
            }
        guard !skills.isEmpty else {
            return ""
        }
        let (inline, callable) = Self.partition(skills)
        var lines: [String] = []
        if !inline.isEmpty {
            lines.append("--- Skills (inline) ---")
            for skill in inline {
                lines.append("\n## \(skill.name)")
                lines.append(skill.description)
                if let body = try? provider.loadBody(for: skill.id), !body.isEmpty {
                    lines.append("")
                    lines.append(body)
                }
            }
            lines.append("")
        }
        if !callable.isEmpty {
            lines.append("--- Skills (load on demand) ---")
            lines
                .append(
                    "You have access to the following skills. When a skill's description matches the user's request, call the `load_skill` tool with that skill's exact `name` to fetch its full instructions.\n"
                )
            for skill in callable {
                lines.append("- \(skill.name) — \(skill.description)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Private

    private static func partition(_ skills: [Skill]) -> (inline: [Skill], callable: [Skill]) {
        var inline: [Skill] = []
        var callable: [Skill] = []
        for skill in skills where skill.alwaysInline {
            inline.append(skill)
        }
        for skill in skills where !skill.alwaysInline {
            callable.append(skill)
        }
        return (inline, callable)
    }

    /// Pick the installed skills whose id is in `allowed`. Falls
    /// back to a lookup on `provider.skills` for ids that aren't
    /// in the globally-enabled baseline — that's how an
    /// "attached on this scope but globally off" skill gets
    /// surfaced to the model.
    private static func resolve(
        allowed: Set<UUID>,
        baseline: [Skill],
        provider: SkillProvider
    ) -> [Skill] {
        let baselineByID = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
        return allowed.compactMap { id in
            baselineByID[id] ?? provider.skill(for: id)
        }
    }
}
