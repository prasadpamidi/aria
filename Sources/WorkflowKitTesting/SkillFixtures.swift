import Foundation
import WorkflowKit

// MARK: - SkillFixtures

/// A skill catalogue on disk, for measuring what an unranked one costs.
///
/// Skills were the last part of the request with no selection at all.
/// Tools are ranked and share-capped; the skill catalogue was pasted
/// whole into every turn, and the model picked from a flat list by
/// name. The field failure that motivated ranking: asked "What's my
/// current weight?" against five enabled skills, a model loaded
/// *Structured output schemas*, then *Email style guide*, then
/// *Markdown formatting guide* — three round-trips and seven seconds of
/// an eleven-second time-to-first-token spent choosing blind from an
/// undifferentiated menu, ending in a context overflow.
///
/// The cost shape differs from tools, which is why it needs its own
/// measurement. An extra *tool* costs its schema in the prompt. An
/// extra *skill* costs the chance the model loads it — a whole
/// round-trip and a body-sized tool result — so the damage is not
/// bounded by the catalogue's token count.
///
/// `SkillProvider` is directory-backed, so fixtures are written to a
/// temporary directory and cleaned up by the caller.
@MainActor
public enum SkillFixtures {
    // MARK: Lifecycle

    /// Bodies are sized like real ones — a skill that costs nothing to
    /// load would not have produced the failure being measured.
    private static func body(for name: String) -> String {
        let paragraph = """
        This section describes the conventions that apply when working with \(name). \
        Follow the guidance below in order, and prefer the most specific rule that \
        applies to the case in front of you rather than the general one.
        """
        return (0..<8).map { "## Section \($0)\n\n\(paragraph)" }.joined(separator: "\n\n")
    }

    // MARK: Public

    /// One case: a question, and the skill that should be loaded for it.
    public struct Case: Sendable {
        // MARK: Lifecycle

        public init(query: String, expectedSkill: String?) {
            self.query = query
            self.expectedSkill = expectedSkill
        }

        // MARK: Public

        public let query: String
        /// The skill a correct selection loads, or `nil` when the
        /// question needs no skill at all.
        public let expectedSkill: String?
    }

    /// The catalogue. Two skills are plausibly relevant to a health
    /// app; the rest are the generic developer skills that a real
    /// install accumulates and that have nothing to do with any
    /// question a user of that app would ask.
    public static let catalogue: [(name: String, description: String)] = [
        (
            "Weight trend analysis",
            "Interpret weight history: moving averages, plateaus, and how to describe a trend without over-reading daily noise."
        ),
        (
            "Fasting protocols",
            "Reference on common intermittent fasting schedules, eating windows, and how to describe fasting progress."
        ),
        (
            "Structured output schemas",
            "How to emit strictly-typed JSON matching a caller-supplied schema, including enums and optional fields."
        ),
        (
            "Email style guide",
            "House style for outbound email: greetings, sign-offs, tone, and when to use bullet points."
        ),
        (
            "Markdown formatting guide",
            "Conventions for headings, tables, code fences, and emphasis in generated markdown."
        ),
        (
            "Summarization rubric",
            "How to compress a long document: what to keep, what to drop, and how to signal omissions."
        ),
        (
            "Commit message conventions",
            "Conventional-commit prefixes, subject-line length, and how to write a body that explains why."
        ),
        (
            "SQL query review",
            "Checklist for reviewing SQL: index usage, N+1 patterns, and unsafe string interpolation."
        ),
        ("Unit test naming", "Naming conventions for test cases so a failure message reads as a sentence."),
        ("Accessibility audit", "How to check a UI for label coverage, contrast ratios, and dynamic type support."),
    ]

    public static func cases() -> [Case] {
        [
            // The field failure, verbatim.
            Case(query: "What's my current weight?", expectedSkill: "Weight trend analysis"),
            Case(query: "How am I doing with fasting today?", expectedSkill: "Fasting protocols"),
            Case(query: "Am I plateauing on weight?", expectedSkill: "Weight trend analysis"),
            // Nothing in the catalogue helps. Loading anything here is
            // pure cost — a round-trip spent to learn nothing.
            Case(query: "What time is it right now?", expectedSkill: nil),
            Case(query: "Log 500 ml of water", expectedSkill: nil),
        ]
    }

    /// Write the catalogue to a fresh temporary directory and return a
    /// provider over it. The caller owns the directory — see
    /// `tearDown(_:)`.
    public static func makeProvider(
        skills: [(name: String, description: String)] = SkillFixtures.catalogue
    ) throws -> (provider: SkillProvider, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aria-skill-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for skill in skills {
            let id = UUID()
            let document = SkillDocument(
                frontmatter: SkillFrontmatter(
                    id: id,
                    name: skill.name,
                    description: skill.description,
                    modelHint: nil,
                    allowedTools: [],
                    alwaysInline: false,
                    version: nil
                ),
                body: Self.body(for: skill.name)
            )
            let manifest = SkillBundleManifest(
                id: id,
                origin: .authored,
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0),
                alwaysInline: false,
                enabled: true
            )
            try SkillBundleWriter.write(
                document: document,
                manifest: manifest,
                to: directory.appendingPathComponent(id.uuidString, isDirectory: true)
            )
        }
        return (SkillProvider(bundlesDirectory: directory), directory)
    }

    public static func tearDown(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}
