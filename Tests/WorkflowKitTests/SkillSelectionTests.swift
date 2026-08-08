import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - SkillSelectionTests

/// Skills were the last part of the request with no selection at all.
///
/// Tools are ranked and share-capped. Skills were advertised in full on
/// every turn, and the model picked from that flat list by name — which
/// is why "What's my current weight?" loaded *Structured output
/// schemas*, *Email style guide* and *Markdown formatting guide* in
/// sequence, three round-trips spent choosing blind before the turn
/// died of context overflow.
@MainActor
@Suite("Skill selection")
struct SkillSelectionTests {
    // MARK: - Ranking

    /// The field failure, inverted: a weight question must surface the
    /// weight skill and leave the formatting guides out.
    @Test func rankingSurfacesTheRelevantSkill() async throws {
        let provider = try Self.provider([
            ("Structured output schemas", "Shapes to use verbatim when the request asks for JSON."),
            ("Email style guide", "Tone and structure for writing cold outreach email."),
            ("Markdown formatting guide", "How to format headings, lists and tables well."),
            ("Body composition", "Interpreting weight trends, body fat and lean mass."),
            ("Recipe writing", "Structure a recipe with ingredients and steps."),
        ])

        let block = await SkillPromptBuilder.systemPromptBlock(
            provider: provider,
            query: "What's my current weight?",
            selector: LexicalToolSelector(),
            limit: 2
        )

        #expect(block.contains("Body composition"))
        #expect(!block.contains("Email style guide"))
        #expect(!block.contains("Markdown formatting guide"))
    }

    /// Only rank under pressure. A catalogue that already fits has
    /// nothing to gain from ranking and everything to lose — a selector
    /// matching two of three would hide the third for free.
    @Test func smallCatalogueIsAdvertisedWhole() async throws {
        let provider = try Self.provider([
            ("Body composition", "Interpreting weight trends."),
            ("Email style guide", "Tone for cold outreach."),
            ("Recipe writing", "Structure a recipe."),
        ])

        let block = await SkillPromptBuilder.systemPromptBlock(
            provider: provider,
            query: "What's my current weight?",
            selector: LexicalToolSelector(),
            limit: 8
        )

        #expect(block.contains("Body composition"))
        #expect(block.contains("Email style guide"))
        #expect(block.contains("Recipe writing"))
    }

    /// An empty ranking means the ranker found no signal, not that
    /// nothing is relevant — the same reading the context assembler
    /// gives it. Hiding the catalogue on an unscoreable query would
    /// leave the model unable to load a skill it might need.
    @Test func unrankableQueryStillAdvertisesSkills() async throws {
        let provider = try Self.provider([
            ("Body composition", "Interpreting weight trends."),
            ("Email style guide", "Tone for cold outreach."),
            ("Recipe writing", "Structure a recipe."),
            ("Travel planning", "Itineraries and packing lists."),
        ])

        let block = await SkillPromptBuilder.systemPromptBlock(
            provider: provider,
            query: "zzzz qqqq",
            selector: LexicalToolSelector(),
            limit: 2
        )

        #expect(block.contains("Skills (load on demand)"))
        #expect(block.contains("Body composition"))
    }

    // MARK: - Inline bodies

    /// Inline bodies land in instructions, and the assembler never
    /// trims instructions. That makes them the one input that can
    /// exceed the window with nothing able to bound it.
    @Test func inlineBodiesAreCapped() async throws {
        let long = String(repeating: "guidance ", count: 2000)
        let provider = try Self.provider([
            ("Big inline skill", "Always applies."),
        ], body: long, alwaysInline: true)

        let block = await SkillPromptBuilder.systemPromptBlock(
            provider: provider,
            query: "anything",
            selector: LexicalToolSelector(),
            inlineBodyLimit: 500
        )

        #expect(block.count < long.count)
        #expect(block.contains("skill truncated"))
    }

    /// The cut is marked, and points at the way to get the rest — a
    /// model reading a fragment it believes is whole follows half a
    /// procedure confidently.
    @Test func truncationPointsAtLoadSkill() async throws {
        let provider = try Self.provider([
            ("Big inline skill", "Always applies."),
        ], body: String(repeating: "x", count: 5000), alwaysInline: true)

        let block = await SkillPromptBuilder.systemPromptBlock(
            provider: provider,
            query: "anything",
            selector: LexicalToolSelector(),
            inlineBodyLimit: 100
        )

        let marker = try #require(block.range(of: "skill truncated"))
        #expect(block[marker.lowerBound...].contains("load_skill"))
    }

    @Test func shortInlineBodiesArePassedThrough() async throws {
        let provider = try Self.provider([
            ("Small inline skill", "Always applies."),
        ], body: "Be concise.", alwaysInline: true)

        let block = await SkillPromptBuilder.systemPromptBlock(
            provider: provider,
            query: "anything",
            selector: LexicalToolSelector(),
            inlineBodyLimit: 4000
        )

        #expect(block.contains("Be concise."))
        #expect(!block.contains("truncated"))
    }

    // MARK: - The unranked overload

    /// Still advertises everything — consumers with a handful of skills
    /// should not be forced to supply a selector.
    @Test func unrankedOverloadAdvertisesEverything() async throws {
        let provider = try Self.provider([
            ("Body composition", "Interpreting weight trends."),
            ("Email style guide", "Tone for cold outreach."),
            ("Recipe writing", "Structure a recipe."),
        ])

        let block = SkillPromptBuilder.systemPromptBlock(provider: provider)

        #expect(block.contains("Body composition"))
        #expect(block.contains("Email style guide"))
        #expect(block.contains("Recipe writing"))
    }

    // MARK: - Fixtures

    private static func provider(
        _ skills: [(name: String, description: String)],
        body: String = "Skill body.",
        alwaysInline: Bool = false
    ) throws -> SkillProvider {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for skill in skills {
            let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let frontmatter = """
            ---
            name: \(skill.name)
            description: \(skill.description)
            always-inline: \(alwaysInline)
            ---
            \(body)
            """
            try frontmatter.write(
                to: directory.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        }
        return SkillProvider(bundlesDirectory: root)
    }
}
