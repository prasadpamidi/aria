import Aria
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

    /// Catalogue only the skills that relate to what was asked.
    ///
    /// The unranked overload below advertises every enabled skill on
    /// every turn, and the model picks from that flat list by name.
    /// Observed: asked "What's my current weight?", a model loaded
    /// *Structured output schemas*, *Email style guide* and *Markdown
    /// formatting guide* in sequence — three round-trips and seven
    /// seconds spent choosing blind from an undifferentiated menu,
    /// ending in a context overflow.
    ///
    /// Skills were the last part of the request with no selection at
    /// all. Tools are ranked and share-capped; skills were neither. A
    /// skill is a name and a description, which is exactly the shape
    /// `ToolSelector` already ranks, so the same selector a consumer
    /// uses for tools works here unchanged — including a fused
    /// lexical + semantic one.
    ///
    /// - Parameters:
    ///   - query: The user's turn. Ranking is per-turn, like tools.
    ///   - selector: Ranks the loadable skills.
    ///   - limit: Most skills to advertise.
    ///   - inlineBodyLimit: Characters allowed per always-inline body,
    ///     or `nil` for no cap.
    ///
    ///     Inline bodies are pasted verbatim into instructions, and the
    ///     assembler never trims instructions — deliberately, since a
    ///     half-truncated system prompt changes behaviour worse than a
    ///     short history does. That makes a few large inline skills the
    ///     one input that can exceed the window with no recourse at
    ///     all, so the cap belongs here, where the text is still known
    ///     to be a skill body rather than anonymous prompt.
    public static func systemPromptBlock(
        provider: SkillProvider,
        allowedSkillIDs: Set<UUID>? = nil,
        query: String,
        selector: any ToolSelector,
        limit: Int = 8,
        inlineBodyLimit: Int? = 4000
    ) async -> String {
        let skills = self.resolvedSkills(provider: provider, allowedSkillIDs: allowedSkillIDs)
        guard !skills.isEmpty else {
            return ""
        }
        let (inline, callable) = Self.partition(skills)
        let ranked = await Self.rank(callable, query: query, selector: selector, limit: limit)
        return Self.render(
            inline: inline,
            callable: ranked,
            provider: provider,
            inlineBodyLimit: inlineBodyLimit
        )
    }

    /// Advertise every enabled skill, unranked.
    ///
    /// Correct when the catalogue is small enough that relevance can't
    /// pay for itself. Past a handful, prefer the ranked overload: the
    /// cost of an unrelated skill is not only its line in the prompt
    /// but the chance the model loads it, which costs a whole
    /// round-trip and a body-sized tool result.
    public static func systemPromptBlock(
        provider: SkillProvider,
        allowedSkillIDs: Set<UUID>? = nil
    ) -> String {
        let skills = self.resolvedSkills(provider: provider, allowedSkillIDs: allowedSkillIDs)
        guard !skills.isEmpty else {
            return ""
        }
        let (inline, callable) = Self.partition(skills)
        return Self.render(
            inline: inline,
            callable: callable,
            provider: provider,
            inlineBodyLimit: nil
        )
    }

    // MARK: Private

    private static func resolvedSkills(
        provider: SkillProvider,
        allowedSkillIDs: Set<UUID>?
    ) -> [Skill] {
        let baseline = provider.enabledSkills()
        guard let allowed = allowedSkillIDs else {
            return baseline
        }
        // Honour per-scope overrides: keep globally enabled ∩ allowed,
        // then add any extras the user attached that aren't in the
        // global set.
        return Self.resolve(allowed: allowed, baseline: baseline, provider: provider)
    }

    /// Rank the loadable skills against the turn.
    ///
    /// An empty ranking means the selector found no signal, not that
    /// nothing is relevant — the same reading `DefaultContextAssembler`
    /// gives it. In that case advertise everything rather than hiding
    /// the catalogue on a query the ranker simply could not score.
    private static func rank(
        _ skills: [Skill],
        query: String,
        selector: any ToolSelector,
        limit: Int
    ) async -> [Skill] {
        // Rank whenever there is a query to rank against.
        //
        // This deliberately does *not* copy the assembler's
        // "only under pressure" rule, and the first version of this
        // function did — which disabled skill ranking entirely for any
        // catalogue smaller than `limit`. Asked how much water they
        // drank, an agent with five skills was still offered all five
        // and loaded *Email style guide*.
        //
        // Tools and skills have different cost shapes. An extra tool
        // costs its schema in the prompt. An extra *skill* costs the
        // chance the model loads it — a whole round-trip and a
        // body-sized result — which is why the pressure that matters
        // here is not how much room is left but how little the skill
        // has to do with the request. The doc comment on this file said
        // exactly that before the code disagreed with it.
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Array(skills.prefix(limit))
        }
        let definitions = skills.map { skill in
            ToolDefinition(
                name: skill.name,
                description: skill.description,
                inputSchema: .object(properties: [:], required: [])
            )
        }
        let ranked = await selector.select(from: definitions, query: query, limit: limit)
        // Nothing matched: advertise nothing.
        //
        // This is the opposite of what the tool path does, and the
        // asymmetry is the point. A turn with no tools cannot act, so
        // an unranked query there means "send what fits". A turn with
        // no skills is *fine* — skills are optional enhancements, and
        // the model answers perfectly well without one.
        //
        // Falling back to the whole catalogue is what put *Summarization
        // rubric* and *Markdown formatting guide* in front of a question
        // about water intake: nothing matched, so everything shipped,
        // and the model dutifully loaded two of them before doing any
        // real work. On this path an unmatched catalogue should cost
        // nothing rather than everything.
        guard !ranked.isEmpty else {
            return []
        }
        let byName = Dictionary(skills.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return ranked.compactMap { byName[$0.name] }
    }

    private static func render(
        inline: [Skill],
        callable: [Skill],
        provider: SkillProvider,
        inlineBodyLimit: Int?
    ) -> String {
        var lines: [String] = []
        if !inline.isEmpty {
            lines.append("--- Skills (inline) ---")
            for skill in inline {
                lines.append("\n## \(skill.name)")
                lines.append(skill.description)
                if let body = try? provider.loadBody(for: skill.id), !body.isEmpty {
                    lines.append("")
                    lines.append(Self.bounded(body, limit: inlineBodyLimit))
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

    /// Cap an inline body, marking the cut so the model knows it is
    /// reading a fragment and can call `load_skill` for the whole thing.
    private static func bounded(_ body: String, limit: Int?) -> String {
        guard let limit, limit > 0, body.count > limit else {
            return body
        }
        return String(body.prefix(limit))
            + "\n\n… [skill truncated to fit the context window — call load_skill for the full text]"
    }

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
