import Foundation
import Observation
import OSLog

// MARK: - SkillProvider

/// In-memory mirror of every installed skill bundle, plus the
/// thin file-system layer that backs them.
///
/// The consumer app picks the on-disk location (typically a
/// directory inside `Application Support/<app>-skills/`) and
/// passes it to `init(bundlesDirectory:)`. The provider scans
/// that directory on init, exposes the result via the
/// `@Observable` `skills` array, and mutates in place on
/// `install` / `delete` / `update` so SwiftUI views read a
/// single coherent state.
///
/// **On-disk layout** under `bundlesDirectory`:
///
///   * `{uuid}/SKILL.md` — canonical bundle file (Anthropic
///     frontmatter + markdown body).
///   * `{uuid}/manifest.json` — metadata sidecar (origin,
///     createdAt, enabled, alwaysInline).
///   * `{uuid}/{helpers,references}/*` — optional reference
///     material the model can read once the body has been
///     loaded.
///
/// **Lifecycle**: one provider per process is the recommended
/// pattern — instantiate at app launch, inject through the
/// SwiftUI environment, and let mutations ripple through the
/// `@Observable` surface.
@MainActor
@Observable
public final class SkillProvider {
    // MARK: Lifecycle

    public init(bundlesDirectory: URL) {
        self.bundlesDirectory = bundlesDirectory
        self.reload()
    }

    // MARK: Public

    public struct LoadError: Sendable, Equatable, Identifiable {
        public let id = UUID()
        public let url: URL
        public let message: String
    }

    /// Surfaces in the Settings list. `Equatable` per-row so
    /// `@Observable` propagation tracks rename + enable-toggle
    /// edits as discrete changes.
    public private(set) var skills: [Skill] = []

    /// Bundles that exist on disk but couldn't be loaded —
    /// surfaced inline in the Settings list so a malformed
    /// frontmatter doesn't silently vanish the row.
    public private(set) var errors: [LoadError] = []

    /// Look up a skill by id. Linear scan, but the list is
    /// always small (~tens of skills), so a hash map isn't worth
    /// the bookkeeping.
    public func skill(for id: UUID) -> Skill? {
        self.skills.first(where: { $0.id == id })
    }

    public func enabledSkills() -> [Skill] {
        self.skills.filter(\.enabled)
    }

    /// Load the markdown body for a skill — performed on demand
    /// rather than at provider init so the in-memory footprint
    /// stays bounded for users with many large skills.
    public func loadBody(for id: UUID) throws -> String {
        guard let skill = self.skill(for: id) else {
            throw SkillProviderError.skillNotFound(id)
        }
        let directory = self.bundlesDirectory
            .appendingPathComponent(skill.bundleRelativePath, isDirectory: true)
        let (document, _) = try SkillBundleReader.read(directoryURL: directory)
        return document.body
    }

    /// Persist a freshly-authored skill: create the per-skill
    /// directory under `bundlesDirectory`, write SKILL.md +
    /// manifest, refresh the in-memory list, and return the
    /// fully-formed `Skill` so callers can immediately push an
    /// editor for it.
    @discardableResult
    public func authorNew(
        name: String,
        description: String,
        body: String,
        modelHint: String? = nil,
        allowedTools: [String] = [],
        alwaysInline: Bool = false,
        version: String? = nil
    ) throws -> Skill {
        let id = UUID()
        let relative = id.uuidString
        let directory = self.bundlesDirectory.appendingPathComponent(relative, isDirectory: true)
        let now = Date()
        let manifest = SkillBundleManifest(
            id: id,
            origin: .authored,
            createdAt: now,
            updatedAt: now,
            alwaysInline: alwaysInline,
            enabled: true
        )
        let document = SkillDocument(
            frontmatter: SkillFrontmatter(
                id: id,
                name: name,
                description: description,
                modelHint: modelHint,
                allowedTools: allowedTools,
                alwaysInline: alwaysInline,
                version: version
            ),
            body: body
        )
        try SkillBundleWriter.write(document: document, manifest: manifest, to: directory)
        self.reload()
        return self.skill(for: id) ?? Self.makeSkill(
            from: document.frontmatter,
            manifest: manifest,
            relative: relative
        )
    }

    /// Replace an existing skill's metadata + body on disk and
    /// in memory.
    public func update(
        id: UUID,
        name: String,
        description: String,
        body: String,
        modelHint: String? = nil,
        allowedTools: [String] = [],
        alwaysInline: Bool = false,
        enabled: Bool = true,
        version: String? = nil
    ) throws {
        guard let skill = self.skill(for: id) else {
            throw SkillProviderError.skillNotFound(id)
        }
        let directory = self.bundlesDirectory.appendingPathComponent(skill.bundleRelativePath, isDirectory: true)
        let manifest = SkillBundleManifest(
            id: id,
            origin: skill.origin,
            createdAt: skill.createdAt,
            updatedAt: Date(),
            alwaysInline: alwaysInline,
            enabled: enabled
        )
        let document = SkillDocument(
            frontmatter: SkillFrontmatter(
                id: id,
                name: name,
                description: description,
                modelHint: modelHint,
                allowedTools: allowedTools,
                alwaysInline: alwaysInline,
                version: version ?? skill.version
            ),
            body: body
        )
        try SkillBundleWriter.write(document: document, manifest: manifest, to: directory)
        self.reload()
    }

    /// Toggle the enabled flag without re-writing the entire
    /// body. Fast path for the Settings list toggle.
    public func setEnabled(_ enabled: Bool, for id: UUID) throws {
        let body = try self.loadBody(for: id)
        guard let skill = self.skill(for: id) else {
            throw SkillProviderError.skillNotFound(id)
        }
        try self.update(
            id: id,
            name: skill.name,
            description: skill.description,
            body: body,
            modelHint: skill.modelHint,
            allowedTools: skill.allowedTools,
            alwaysInline: skill.alwaysInline,
            enabled: enabled
        )
    }

    /// Delete a skill bundle off disk and from the in-memory
    /// list. Idempotent.
    public func delete(id: UUID) throws {
        guard let skill = self.skill(for: id) else {
            return
        }
        let directory = self.bundlesDirectory.appendingPathComponent(skill.bundleRelativePath, isDirectory: true)
        try SkillBundleWriter.delete(directoryURL: directory)
        self.reload()
    }

    /// Re-scan the bundles directory. Called on init + after
    /// every mutation. Errors surface on `errors` rather than
    /// throwing so a single bad bundle doesn't blank the entire
    /// Settings list.
    public func reload() {
        var loaded: [Skill] = []
        var encountered: [LoadError] = []
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: self.bundlesDirectory.path) {
            try? fileManager.createDirectory(
                at: self.bundlesDirectory,
                withIntermediateDirectories: true
            )
        }
        for directory in SkillBundleReader.enumerateBundleDirectories(under: self.bundlesDirectory) {
            do {
                let (document, manifest) = try SkillBundleReader.read(directoryURL: directory)
                let resolvedManifest = manifest ?? Self.synthesisedManifest(from: document, directoryURL: directory)
                let relative = directory.lastPathComponent
                loaded.append(Self.makeSkill(
                    from: document.frontmatter,
                    manifest: resolvedManifest,
                    relative: relative
                ))
            } catch {
                encountered.append(LoadError(url: directory, message: error.localizedDescription))
            }
        }
        self.skills = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.errors = encountered
    }

    // MARK: Internal

    let bundlesDirectory: URL

    // MARK: Private

    private static let log = Logger(
        subsystem: "com.aria.sdk.workflowkit",
        category: "SkillProvider"
    )

    private static func makeSkill(
        from frontmatter: SkillFrontmatter,
        manifest: SkillBundleManifest,
        relative: String
    ) -> Skill {
        Skill(
            id: manifest.id,
            name: frontmatter.name,
            description: frontmatter.description,
            modelHint: frontmatter.modelHint,
            allowedTools: frontmatter.allowedTools,
            alwaysInline: manifest.alwaysInline,
            enabled: manifest.enabled,
            origin: manifest.origin,
            bundleRelativePath: relative,
            version: frontmatter.version,
            createdAt: manifest.createdAt,
            updatedAt: manifest.updatedAt
        )
    }

    /// Synthesise a manifest for a bundle that arrived without
    /// one (e.g. a raw SKILL.md the user dropped in via Files).
    /// Treats it as `imported` from the bundle's mtime.
    private static func synthesisedManifest(
        from document: SkillDocument,
        directoryURL: URL
    ) -> SkillBundleManifest {
        let id = document.frontmatter.id ?? UUID()
        let mtime = (
            try? FileManager.default.attributesOfItem(atPath: directoryURL.path)[.modificationDate] as? Date
        ) ??
            Date()
        return SkillBundleManifest(
            id: id,
            origin: .imported,
            createdAt: mtime,
            updatedAt: mtime,
            alwaysInline: document.frontmatter.alwaysInline,
            enabled: true
        )
    }
}

// MARK: - SkillProviderError

public enum SkillProviderError: Error, LocalizedError, Equatable {
    case skillNotFound(UUID)

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case let .skillNotFound(id):
            "No skill found with id \(id.uuidString)."
        }
    }
}
