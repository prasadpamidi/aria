import Foundation
import Observation

// MARK: - SkeletonTemplateCatalog

/// In-memory registry of skeleton templates surfaced in the
/// editor's "New workflow" sheet. Skeleton templates aren't
/// persisted to the workflow store — they live here as a
/// catalogue the editor reads, and are cloned into the user's
/// library on demand when the user picks one.
///
/// `@Observable` so SwiftUI surfaces re-render when the seeder
/// pushes new templates in (e.g. after a "Restore defaults"
/// action).
@MainActor
@Observable
public final class SkeletonTemplateCatalog {
    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    /// One skeleton entry the editor renders as a card in the
    /// "New workflow" sheet.
    public struct Entry: Sendable, Equatable, Identifiable {
        // MARK: Lifecycle

        public init(
            name: String,
            summary: String,
            category: SeedCategory,
            workflow: Workflow
        ) {
            self.name = name
            self.summary = summary
            self.category = category
            self.workflow = workflow
        }

        // MARK: Public

        public let name: String
        public let summary: String
        public let category: SeedCategory
        public let workflow: Workflow

        public var id: UUID {
            self.workflow.id
        }
    }

    public private(set) var entries: [Entry] = []

    /// Replace the catalogue. Called by `SeedInstaller` at
    /// app launch (or on Restore defaults). Templates are
    /// stateless — re-installing is cheap.
    public func replace(_ entries: [Entry]) {
        self.entries = entries
    }

    public func entries(in category: SeedCategory) -> [Entry] {
        self.entries.filter { $0.category == category }
    }
}

// MARK: - WorkflowCatalog

/// In-memory registry of prebuilt workflows shipped by the
/// catalogue. Distinct from `WorkflowStore` — store holds
/// USER workflows (authored + remixed); catalogue holds
/// first-party content the user can browse + Remix but can't
/// directly edit. Tap "Run" to invoke a catalogue entry as-is;
/// tap "Remix" to clone it into the store with a new id.
///
/// `@Observable` so the Workflow Gallery re-renders when the
/// installer pushes a new set (e.g. after "Restore defaults").
@MainActor
@Observable
public final class WorkflowCatalog {
    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    public struct Entry: Sendable, Equatable, Identifiable {
        // MARK: Lifecycle

        public init(workflow: Workflow, category: SeedCategory) {
            self.workflow = workflow
            self.category = category
        }

        // MARK: Public

        public let workflow: Workflow
        public let category: SeedCategory

        public var id: UUID {
            self.workflow.id
        }
    }

    public private(set) var entries: [Entry] = []

    public func replace(_ entries: [Entry]) {
        self.entries = entries
    }

    public func entry(for id: UUID) -> Entry? {
        self.entries.first { $0.id == id }
    }

    public func entries(in category: SeedCategory) -> [Entry] {
        self.entries.filter { $0.category == category }
    }
}

// MARK: - SnippetCatalog

/// Mirror of `SkeletonTemplateCatalog` for prompt snippets.
/// Held in memory + re-installed at launch from the seed
/// source. The editor reads from here to populate the
/// "Snippets" chip rail on LLM step prompt fields.
@MainActor
@Observable
public final class SnippetCatalog {
    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    public struct Entry: Sendable, Equatable, Identifiable {
        // MARK: Lifecycle

        public init(name: String, body: String, category: SnippetCategory) {
            self.name = name
            self.body = body
            self.category = category
        }

        // MARK: Public

        public let name: String
        public let body: String
        public let category: SnippetCategory

        public var id: String {
            "\(self.category.rawValue).\(self.name)"
        }
    }

    public private(set) var entries: [Entry] = []

    public func replace(_ entries: [Entry]) {
        self.entries = entries
    }

    public func entries(in category: SnippetCategory) -> [Entry] {
        self.entries.filter { $0.category == category }
    }
}
