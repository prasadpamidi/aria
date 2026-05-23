import Foundation

// MARK: - Skill

/// A user-installable instruction bundle that gives the LLM new
/// behaviours without code. Modelled on Anthropic's published
/// skill pattern: a `SKILL.md` file with YAML frontmatter
/// (descriptive metadata the model sees up-front) plus a
/// markdown body (the full instructions, loaded on demand).
///
/// Skills are referenced by both the chat surface and workflow
/// LLM steps. The runtime exposes them via:
///
///   1. **Tool-call activation** (default): the model sees each
///      enabled skill's `description` in the system prompt and
///      invokes the synthetic `load_skill(name)` tool when it
///      decides the skill applies.
///   2. **Always-inline** (opt-in per skill): the body is
///      appended to the system prompt verbatim, no round-trip.
///      Used for short personality / style skills.
///
/// `Skill.id` is a stable UUID independent of the human-readable
/// `name`, so renames don't break workflow references. The
/// `bundleRelativePath` resolves under the host app's
/// chosen skills directory (typically
/// `Application Support/<app>-skills/`).
public struct Skill: Codable, Identifiable, Hashable, Sendable {
    // MARK: Lifecycle

    public init(
        id: UUID = UUID(),
        name: String,
        description: String,
        modelHint: String? = nil,
        allowedTools: [String] = [],
        alwaysInline: Bool = false,
        enabled: Bool = true,
        origin: Origin = .authored,
        bundleRelativePath: String,
        version: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.modelHint = modelHint
        self.allowedTools = allowedTools
        self.alwaysInline = alwaysInline
        self.enabled = enabled
        self.origin = origin
        self.bundleRelativePath = bundleRelativePath
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: Public

    /// How the skill landed on the device. Drives the badge
    /// shown in the Settings list and influences re-export
    /// behaviour (imported / downloaded skills can be re-shared
    /// as-is; authored skills get a fresh bundle build).
    public enum Origin: String, Codable, Sendable {
        /// Created in-app via the authoring editor.
        case authored
        /// Imported from a `.zip` skill bundle on the device.
        case imported
        /// Fetched from a remote URL (raw `SKILL.md` or zip).
        case downloaded
    }

    /// Stable identifier — UUID rather than slugged-name so
    /// renaming the skill never invalidates workflow refs that
    /// pin to it. Persisted in the bundle's frontmatter as
    /// `id:` for round-trip on export → reimport.
    public let id: UUID

    /// Human-readable name. Free-text, used in the picker UI
    /// and as the argument the model passes to `load_skill`.
    public var name: String

    /// Single-paragraph summary the model sees in the system
    /// prompt. Should be specific enough that the model can
    /// tell whether the skill applies to the user's task —
    /// vague descriptions cause both false positives (the
    /// skill activates when it shouldn't) and false negatives
    /// (the skill never gets picked).
    public var description: String

    /// Optional advisory hint from frontmatter — e.g.
    /// "claude-3-5-sonnet" or "qwen-3-4b". Not enforced; only
    /// surfaced in the UI so a power user can match the skill
    /// against the active model.
    public var modelHint: String?

    /// Tool names this skill is allowed to invoke. Parsed +
    /// stored from frontmatter `allowed-tools` but not yet
    /// enforced in P0 (see plan §7 open question 3).
    public var allowedTools: [String]

    /// When `true`, the body is appended to the system prompt
    /// verbatim instead of just the description. Use for short
    /// personality / style skills where the round-trip cost of
    /// `load_skill` doesn't pay for itself.
    public var alwaysInline: Bool

    /// User-toggle in Settings → Skills. Disabled skills are
    /// invisible to the agent regardless of activation strategy.
    public var enabled: Bool

    public var origin: Origin

    /// Relative path under the host app's skills directory —
    /// typically the skill's UUID string for authored / imported
    /// bundles, or a deterministic slug for downloads.
    public var bundleRelativePath: String

    /// Optional semver-ish version string. Used by the future
    /// "check for updates" path (plan §7 open question 6); P0
    /// just round-trips it.
    public var version: String?

    public let createdAt: Date
    public var updatedAt: Date
}

// MARK: - SkillFrontmatter

/// Parsed representation of the YAML frontmatter block at the
/// top of a `SKILL.md` file. Kept separate from `Skill` so the
/// frontmatter parser can populate this raw bag before the
/// store decides on persisted fields like `id` and `createdAt`.
public struct SkillFrontmatter: Hashable, Sendable {
    // MARK: Lifecycle

    public init(
        id: UUID? = nil,
        name: String,
        description: String,
        modelHint: String? = nil,
        allowedTools: [String] = [],
        alwaysInline: Bool = false,
        version: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.modelHint = modelHint
        self.allowedTools = allowedTools
        self.alwaysInline = alwaysInline
        self.version = version
    }

    // MARK: Public

    public let id: UUID?
    public let name: String
    public let description: String
    public let modelHint: String?
    public let allowedTools: [String]
    public let alwaysInline: Bool
    public let version: String?
}

// MARK: - SkillDocument

/// Parsed in-memory representation of a `SKILL.md` file. The
/// store uses this as the round-trip type: read disk → parse →
/// edit → re-serialise → write disk. Splitting from `Skill`
/// keeps the runtime model lightweight (no body in memory by
/// default) while still letting the editor work against the
/// full bundle when needed.
public struct SkillDocument: Sendable {
    // MARK: Lifecycle

    public init(frontmatter: SkillFrontmatter, body: String) {
        self.frontmatter = frontmatter
        self.body = body
    }

    // MARK: Public

    public let frontmatter: SkillFrontmatter

    /// Markdown body — everything after the frontmatter block.
    /// May be empty for skills whose entire instruction set
    /// fits in the description (rare; usually only personas).
    public let body: String
}

// MARK: - SkillBundleManifest

/// Disk layout sidecar — what's actually stored on disk for a
/// skill. The `Skill` value is the runtime mirror; the manifest
/// is the source of truth that survives uninstall / reinstall
/// since it lives next to `SKILL.md`.
public struct SkillBundleManifest: Codable, Sendable {
    // MARK: Lifecycle

    public init(
        id: UUID,
        origin: Skill.Origin,
        createdAt: Date,
        updatedAt: Date,
        alwaysInline: Bool,
        enabled: Bool
    ) {
        self.id = id
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.alwaysInline = alwaysInline
        self.enabled = enabled
    }

    // MARK: Public

    public let id: UUID
    public let origin: Skill.Origin
    public let createdAt: Date
    public var updatedAt: Date
    public var alwaysInline: Bool
    public var enabled: Bool
}

// MARK: - SkillError

public enum SkillError: Error, LocalizedError, Equatable {
    case missingFrontmatter
    case malformedFrontmatter(String)
    case missingRequiredField(String)
    case bundleNotFound(URL)
    case unreadableSkillFile(URL)

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case .missingFrontmatter:
            "SKILL.md is missing the YAML frontmatter block (no `---` markers found)."
        case let .malformedFrontmatter(detail):
            "YAML frontmatter is malformed: \(detail)"
        case let .missingRequiredField(field):
            "Frontmatter is missing the required `\(field)` field."
        case let .bundleNotFound(url):
            "No skill bundle exists at \(url.path)."
        case let .unreadableSkillFile(url):
            "Couldn't read SKILL.md at \(url.path)."
        }
    }
}
