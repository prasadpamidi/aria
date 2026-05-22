import Foundation
import Testing
@testable import WorkflowKit

// MARK: - SkillFrontmatterParserTests

@Suite("SkillFrontmatterParser")
struct SkillFrontmatterParserTests {
    @Test
    func parsesMinimalFrontmatter() throws {
        let raw = """
        ---
        name: meeting-notes
        description: Format meeting notes with attendees and action items.
        ---

        # Meeting notes skill body
        """
        let document = try SkillFrontmatterParser.parse(raw)
        #expect(document.frontmatter.name == "meeting-notes")
        #expect(document.frontmatter.description == "Format meeting notes with attendees and action items.")
        #expect(document.frontmatter.id == nil)
        #expect(document.frontmatter.allowedTools.isEmpty)
        #expect(document.frontmatter.alwaysInline == false)
        #expect(document.body.contains("Meeting notes skill body"))
    }

    @Test
    func parsesFullFrontmatter() throws {
        let raw = """
        ---
        id: 11111111-2222-3333-4444-555555555555
        name: code-review
        description: "Walk through code review with security, readability, and tests."
        model: claude-3-5-sonnet
        allowed-tools: [Read, Grep]
        always-inline: true
        version: 1.0.0
        ---

        Body here.
        """
        let document = try SkillFrontmatterParser.parse(raw)
        #expect(document.frontmatter.id == UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        #expect(document.frontmatter.name == "code-review")
        #expect(document.frontmatter.modelHint == "claude-3-5-sonnet")
        #expect(document.frontmatter.allowedTools == ["Read", "Grep"])
        #expect(document.frontmatter.alwaysInline == true)
        #expect(document.frontmatter.version == "1.0.0")
    }

    @Test
    func parsesBlockListAllowedTools() throws {
        let raw = """
        ---
        name: skill
        description: A
        allowed-tools:
          - Read
          - Write
          - Grep
        ---
        body
        """
        let document = try SkillFrontmatterParser.parse(raw)
        #expect(document.frontmatter.allowedTools == ["Read", "Write", "Grep"])
    }

    @Test
    func stripsTrailingComments() throws {
        let raw = """
        ---
        name: skill # comment with: colon
        description: Hello # trailing
        ---
        body
        """
        let document = try SkillFrontmatterParser.parse(raw)
        #expect(document.frontmatter.name == "skill")
        #expect(document.frontmatter.description == "Hello")
    }

    @Test
    func keepsHashesInsideQuotes() throws {
        let raw = """
        ---
        name: skill
        description: "Use #hashtags for fun"
        ---
        body
        """
        let document = try SkillFrontmatterParser.parse(raw)
        #expect(document.frontmatter.description == "Use #hashtags for fun")
    }

    @Test
    func throwsWhenFrontmatterMissing() {
        let raw = "no frontmatter here, just a body"
        #expect(throws: SkillError.missingFrontmatter) {
            try SkillFrontmatterParser.parse(raw)
        }
    }

    @Test
    func throwsWhenClosingFenceMissing() {
        let raw = """
        ---
        name: skill
        description: never closed
        """
        #expect(throws: SkillError.missingFrontmatter) {
            try SkillFrontmatterParser.parse(raw)
        }
    }

    @Test
    func throwsWhenNameMissing() {
        let raw = """
        ---
        description: A skill with no name.
        ---
        body
        """
        #expect(throws: SkillError.missingRequiredField("name")) {
            try SkillFrontmatterParser.parse(raw)
        }
    }

    @Test
    func throwsWhenDescriptionMissing() {
        let raw = """
        ---
        name: nameOnly
        ---
        body
        """
        #expect(throws: SkillError.missingRequiredField("description")) {
            try SkillFrontmatterParser.parse(raw)
        }
    }
}

// MARK: - SkillFrontmatterRoundtripTests

@Suite("SkillFrontmatter round-trip")
struct SkillFrontmatterRoundtripTests {
    @Test
    func parseSerialiseParsePreservesFields() throws {
        let original = """
        ---
        id: 11111111-2222-3333-4444-555555555555
        name: code-review
        description: "Walk through code review with security, readability, and tests."
        model: claude-3-5-sonnet
        allowed-tools: [Read, Grep]
        always-inline: true
        version: 1.0.0
        ---

        # Body
        Some markdown content.
        """
        let parsed = try SkillFrontmatterParser.parse(original)
        let id = parsed.frontmatter.id ?? UUID()
        let serialised = SkillFrontmatterSerialiser.serialise(document: parsed, manifestID: id)
        let reparsed = try SkillFrontmatterParser.parse(serialised)
        #expect(reparsed.frontmatter.id == id)
        #expect(reparsed.frontmatter.name == parsed.frontmatter.name)
        #expect(reparsed.frontmatter.description == parsed.frontmatter.description)
        #expect(reparsed.frontmatter.modelHint == parsed.frontmatter.modelHint)
        #expect(reparsed.frontmatter.allowedTools == parsed.frontmatter.allowedTools)
        #expect(reparsed.frontmatter.alwaysInline == parsed.frontmatter.alwaysInline)
        #expect(reparsed.frontmatter.version == parsed.frontmatter.version)
    }
}

// MARK: - SkillBundleReaderTests

@Suite("SkillBundleReader")
struct SkillBundleReaderTests {
    @Test
    func readsBundleFromDisk() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-bundle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let skillID = UUID()
        let document = SkillDocument(
            frontmatter: SkillFrontmatter(
                id: skillID,
                name: "test-skill",
                description: "A test."
            ),
            body: "# Body\nLine."
        )
        let manifest = SkillBundleManifest(
            id: skillID,
            origin: .authored,
            createdAt: Date(),
            updatedAt: Date(),
            alwaysInline: false,
            enabled: true
        )
        try SkillBundleWriter.write(document: document, manifest: manifest, to: tempDir)

        let (readDocument, readManifest) = try SkillBundleReader.read(directoryURL: tempDir)
        #expect(readDocument.frontmatter.name == "test-skill")
        #expect(readDocument.frontmatter.id == skillID)
        #expect(readManifest != nil)
        #expect(readManifest?.id == skillID)
        #expect(readManifest?.origin == .authored)
    }

    @Test
    func enumeratesBundlesUnderRoot() throws {
        let rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let bundleA = rootDir.appendingPathComponent("a")
        let bundleB = rootDir.appendingPathComponent("b")
        let stray = rootDir.appendingPathComponent("not-a-bundle")
        try FileManager.default.createDirectory(at: bundleA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try "---\nname: a\ndescription: a\n---\nbody"
            .write(to: bundleA.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "---\nname: b\ndescription: b\n---\nbody"
            .write(to: bundleB.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        // `stray` has no SKILL.md — should be filtered out.

        let bundles = SkillBundleReader.enumerateBundleDirectories(under: rootDir)
        let names = bundles.map(\.lastPathComponent).sorted()
        #expect(names == ["a", "b"])
    }

    @Test
    func reportsMissingBundle() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        #expect(throws: SkillError.bundleNotFound(url)) {
            try SkillBundleReader.read(directoryURL: url)
        }
    }
}
