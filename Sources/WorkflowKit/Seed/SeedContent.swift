import Foundation

// MARK: - SeedContent

/// Discriminated union of every kind of seedable content a host
/// app installs on first launch. One mechanism delivers prebuilt
/// workflows, JS plugin tools, workflow skeleton templates, and
/// prompt snippets — every piece can live in the same source
/// pack ("Daily Essentials", "Health", …) and the installer
/// dispatches by case.
public enum SeedContent: Sendable {
    /// Ready-to-run workflow — appears in the user's library
    /// the first time they launch the app. Categorised so the
    /// Workflow Gallery can group by pack.
    case workflow(Workflow, category: SeedCategory)

    /// Skeleton workflow surfaced in the "New workflow" sheet
    /// alongside "Blank workflow." The user picks one and the
    /// editor opens with the skeleton's nodes pre-wired.
    /// Templates aren't persisted to the workflow store
    /// directly — they live in the catalogue and are cloned
    /// into the user's library on demand.
    case skeletonTemplate(
        workflow: Workflow,
        name: String,
        summary: String,
        category: SeedCategory
    )

    /// First-party JS plugin tool. `bundleData` is the raw
    /// plugin JSON (default `.aria-tool`). The app-side
    /// `SeedPluginInstaller` routes this to the running
    /// `JSToolProvider`.
    case jsPluginTool(bundleData: Data, name: String)

    /// Single prompt snippet — name + body + category. Used
    /// to populate the workflow editor's "Snippets" chip rail
    /// on the LLM step prompt field.
    case promptSnippet(name: String, body: String, category: SnippetCategory)
}

// MARK: - SeedCategory

/// The 8 packs the catalogue ships with at v1.1. Each pack
/// targets a different persona / use case; the Workflow Gallery
/// groups its sections by these.
public enum SeedCategory: String, Sendable, CaseIterable, Codable {
    case dailyEssentials
    case health
    case productivity
    case knowledge
    case family
    case developer
    case creative
    case grocery
    // v1.2 additions targeted at paying demographics.
    // `Codable(rawValue:)` is the only on-disk identity that
    // matters here — keep these raw strings stable forever so
    // existing seeded workflows in users' stores resolve back
    // to the correct category after this SDK bump.
    case sales
    case students
    case travel
    case analytics

    // MARK: Public

    /// Human-readable label for the gallery section header.
    public var displayName: String {
        switch self {
        case .dailyEssentials: "Daily Essentials"
        case .health: "Health & Fitness"
        case .productivity: "Productivity"
        case .knowledge: "Knowledge Work"
        case .family: "Family"
        case .developer: "Developer"
        case .creative: "Creative"
        case .grocery: "Grocery + Pantry"
        case .sales: "Sales"
        case .students: "Students"
        case .travel: "Travel"
        case .analytics: "Analytics"
        }
    }

    /// SF Symbol used in the gallery section header. Consumers
    /// that ship custom asset packs (e.g. Avyra's Vuesax pack)
    /// override this with their own mapping; the SF Symbol
    /// fallback here keeps Niora + any other SDK consumer
    /// running without a hard dependency on the icon pack.
    public var symbol: String {
        switch self {
        case .dailyEssentials: "sun.max"
        case .health: "heart"
        case .productivity: "calendar.badge.clock"
        case .knowledge: "books.vertical"
        case .family: "person.3"
        case .developer: "chevron.left.forwardslash.chevron.right"
        case .creative: "sparkles"
        case .grocery: "cart"
        case .sales: "briefcase"
        case .students: "graduationcap"
        case .travel: "airplane"
        case .analytics: "chart.bar"
        }
    }
}

// MARK: - SnippetCategory

/// Top-level categories for the LLM-step prompt snippets. Keeps
/// the snippet picker organised when the catalogue grows past
/// the initial ~20.
public enum SnippetCategory: String, Sendable, CaseIterable, Codable {
    case extraction
    case summarize
    case translate
    case classify
    case reformat
    case toneShift
    case qa
    case structured
    case generate
    case reasonStepByStep
    case compare

    // MARK: Public

    public var displayName: String {
        switch self {
        case .extraction: "Extraction"
        case .summarize: "Summarize"
        case .translate: "Translate"
        case .classify: "Classify"
        case .reformat: "Reformat"
        case .toneShift: "Tone"
        case .qa: "Q&A"
        case .structured: "Structured output"
        case .generate: "Generate"
        case .reasonStepByStep: "Step-by-step"
        case .compare: "Compare"
        }
    }
}

// MARK: - SeedContentSource

/// Each pack (Daily Essentials, Health, …) is a value-typed
/// content source. The seeder collects every source's
/// `contents` array and installs the lot. Implementations are
/// `Sendable` so the seeder can fan-out across threads safely.
public protocol SeedContentSource: Sendable {
    var contents: [SeedContent] { get }
}

// MARK: - SeedPluginInstaller

/// Injection seam for installing JS plugin tools. Lives in
/// `WorkflowKit` as a protocol because the actual provider
/// (`JSToolProvider`) lives in `AriaToolsJS` — pulling that
/// dep into WorkflowKit would invert the layering. The app
/// wires a thin adapter from JSToolProvider into this
/// protocol.
public protocol SeedPluginInstaller: Sendable {
    /// Returns the set of plugin ids already installed, so the
    /// seeder can skip ones it shouldn't re-install.
    func installedPluginIDs() async -> Set<String>

    /// Install a fresh plugin bundle (raw JSON). The implementation
    /// is responsible for parsing the JSON, validating the
    /// manifest, and persisting under the user's plugin
    /// directory.
    func install(bundleData: Data) async throws
}

// MARK: - SeedSnippetSink

/// Lightweight injection seam for the prompt-snippet catalogue.
/// First-party snippets aren't persisted — they're re-installed
/// from the seed source at every app launch. A future "user
/// authored snippets" surface can extend the sink to persist.
public protocol SeedSnippetSink: Sendable {
    func clearAll() async
    func install(name: String, body: String, category: SnippetCategory) async
}
