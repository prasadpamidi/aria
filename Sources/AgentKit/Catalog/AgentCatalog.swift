import Foundation
import Observation

// MARK: - AgentPersona

/// Top-level grouping the agent gallery uses to organise the
/// catalogue. Roughly "which slice of the user's day does this serve"
/// rather than a tool-surface taxonomy — picked so a non-technical
/// user scans the buckets and immediately knows which one to open.
///
/// Mirrors `SeedCategory` for workflows but keeps the agent vocabulary
/// distinct (workflows are recipes; agents are goals). Stable raw
/// values so a serialised catalogue entry's persona survives store
/// round-trips and the Home tab's "Suggested for now" rail can pin to
/// a persona key.
public enum AgentPersona: String, Sendable, CaseIterable, Codable {
    /// Calendar / reminders / day-shape agents.
    case yourDay
    /// Wellness, hydration, movement, sleep.
    case healthAndBody
    /// Drafting messages, replies, notes.
    case communication
    /// Capturing into the right primitive (clipboard, photo, voice).
    case capture
    /// Pomodoro, deep work, distraction guards.
    case focus
    /// Knowledge surfacing — research, source verification, summarisation.
    case research

    // MARK: Public

    /// Human-readable bucket label for the gallery's section
    /// headers and pill row.
    public var displayName: String {
        switch self {
        case .yourDay: "For your day"
        case .healthAndBody: "Health & body"
        case .communication: "Communication"
        case .capture: "Capture & notes"
        case .focus: "Focus"
        case .research: "Research"
        }
    }

    /// SF Symbol the gallery cards + hero band lean on. Picked to
    /// read at small sizes and stay distinct across personas.
    public var symbolName: String {
        switch self {
        case .yourDay: "sun.max"
        case .healthAndBody: "heart.text.square"
        case .communication: "bubble.left.and.text.bubble.right"
        case .capture: "tray.and.arrow.down"
        case .focus: "timer"
        case .research: "magnifyingglass"
        }
    }

    /// Tag string surfaced on hero band — same convention workflow
    /// catalogue uses (uppercase, spaced).
    public var displayTag: String {
        self.displayName.uppercased()
    }
}

// MARK: - AgentCatalog

/// In-memory registry of curated agents the gallery surfaces as
/// **read-only** content the user can browse, Run, or Remix into
/// their `AgentStore`. Mirrors `WorkflowCatalog` so the home surface
/// can lean on identical layout / filter / detail patterns.
///
/// Population is the host app's responsibility — populate at boot
/// with whatever curated content the app ships, the same way avyra
/// hands `WorkflowCatalog` its packs.
@MainActor
@Observable
public final class AgentCatalog {
    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    /// One catalogue entry the gallery renders as a card. Carries
    /// the full `AgentDefinition` (so the detail screen can show
    /// the storyboard / tool surface without a second load) plus
    /// the persona used for grouping.
    public struct Entry: Sendable, Equatable, Identifiable {
        // MARK: Lifecycle

        public init(definition: AgentDefinition, persona: AgentPersona) {
            self.definition = definition
            self.persona = persona
        }

        // MARK: Public

        public let definition: AgentDefinition
        public let persona: AgentPersona

        public var id: UUID {
            self.definition.id
        }
    }

    public private(set) var entries: [Entry] = []

    /// Personas with at least one curated agent — used by the
    /// gallery to drive its filter pill row (no point showing a
    /// pill for an empty bucket).
    public var populatedPersonas: [AgentPersona] {
        var seen = Set<AgentPersona>()
        var ordered: [AgentPersona] = []
        for entry in self.entries where !seen.contains(entry.persona) {
            seen.insert(entry.persona)
            ordered.append(entry.persona)
        }
        return ordered
    }

    /// Replace the catalogue wholesale. Called by the host at boot
    /// (or after a "Restore defaults" action). Re-installing is
    /// cheap — entries are stateless value types.
    public func replace(_ entries: [Entry]) {
        self.entries = entries
    }

    public func entry(for id: UUID) -> Entry? {
        self.entries.first { $0.id == id }
    }

    public func entries(in persona: AgentPersona) -> [Entry] {
        self.entries.filter { $0.persona == persona }
    }
}

// MARK: - AgentSkeletonTemplateCatalog

/// Mirror of `SkeletonTemplateCatalog` for agents — entries here
/// power the "New agent" sheet's "Start from a template" section.
/// Each entry holds a wired `AgentDefinition` (system prompt, tool
/// surface, approval policy) that gets cloned with a fresh UUID into
/// the user's `AgentStore` when picked, then the editor opens on the
/// clone.
@MainActor
@Observable
public final class AgentSkeletonTemplateCatalog {
    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    public struct Entry: Sendable, Equatable, Identifiable {
        // MARK: Lifecycle

        public init(
            name: String,
            summary: String,
            symbolName: String,
            definition: AgentDefinition
        ) {
            self.name = name
            self.summary = summary
            self.symbolName = symbolName
            self.definition = definition
        }

        // MARK: Public

        /// Display label for the template card. Often distinct from
        /// `definition.name` (a more descriptive label here, while
        /// `definition.name` is what becomes the user's agent name
        /// on first clone).
        public let name: String
        /// One-liner explaining what the user gets when they pick
        /// this — what tools wire in, what the prompt nudges toward.
        public let summary: String
        /// SF Symbol for the template card chrome.
        public let symbolName: String
        public let definition: AgentDefinition

        public var id: UUID {
            self.definition.id
        }
    }

    public private(set) var entries: [Entry] = []

    public func replace(_ entries: [Entry]) {
        self.entries = entries
    }
}
