import Foundation
import Observation

// MARK: - SeedInstaller

/// Installs the catalogue into the user's app on first launch
/// (and on demand via "Restore defaults"). Idempotent —
/// re-running the installer doesn't duplicate content.
///
/// Two important boundaries:
///   - Prebuilt workflows land in the **`WorkflowCatalog`**
///     (in-memory, replaced wholesale on each install). The
///     user-facing `WorkflowStore` only holds workflows the
///     user authored or Remixed; the installer never writes
///     there.
///   - Snippets + skeleton templates also replace wholesale
///     (they're catalogue-owned).
///   - Plugin tools install through the optional
///     `SeedPluginInstaller` adapter, skipped when already
///     loaded.
///
/// `@MainActor` because every catalogue it writes to is
/// MainActor-isolated (`@Observable` containers consumed by
/// SwiftUI views).
@MainActor
public final class SeedInstaller {
    // MARK: Lifecycle

    public init(
        workflowCatalog: WorkflowCatalog,
        skeletonCatalog: SkeletonTemplateCatalog,
        snippetCatalog: SnippetCatalog,
        pluginInstaller: (any SeedPluginInstaller)? = nil,
        snippetSink: (any SeedSnippetSink)? = nil
    ) {
        self.workflowCatalog = workflowCatalog
        self.skeletonCatalog = skeletonCatalog
        self.snippetCatalog = snippetCatalog
        self.pluginInstaller = pluginInstaller
        self.snippetSink = snippetSink
    }

    // MARK: Public

    public func installIfNeeded(sources: [any SeedContentSource]) async throws {
        var workflows: [WorkflowCatalog.Entry] = []
        var skeletons: [SkeletonTemplateCatalog.Entry] = []
        var snippets: [SnippetCatalog.Entry] = []
        let installedPluginIDs = await self.pluginInstaller?.installedPluginIDs() ?? []
        for source in sources {
            for content in source.contents {
                try await self.install(
                    content: content,
                    workflows: &workflows,
                    skeletons: &skeletons,
                    snippets: &snippets,
                    installedPluginIDs: installedPluginIDs
                )
            }
        }
        self.workflowCatalog.replace(workflows)
        self.skeletonCatalog.replace(skeletons)
        self.snippetCatalog.replace(snippets)
        if let snippetSink {
            await snippetSink.clearAll()
            for entry in snippets {
                await snippetSink.install(
                    name: entry.name,
                    body: entry.body,
                    category: entry.category
                )
            }
        }
    }

    /// Force-restore the catalogue. Same idempotency as
    /// `installIfNeeded` — user-authored / remixed workflows
    /// in `WorkflowStore` are NEVER touched (the installer
    /// doesn't write there). Catalogue replaces wholesale.
    public func restoreDefaults(sources: [any SeedContentSource]) async throws {
        try await self.installIfNeeded(sources: sources)
    }

    // MARK: Private

    private let workflowCatalog: WorkflowCatalog
    private let skeletonCatalog: SkeletonTemplateCatalog
    private let snippetCatalog: SnippetCatalog
    private let pluginInstaller: (any SeedPluginInstaller)?
    private let snippetSink: (any SeedSnippetSink)?

    private func install(
        content: SeedContent,
        workflows: inout [WorkflowCatalog.Entry],
        skeletons: inout [SkeletonTemplateCatalog.Entry],
        snippets: inout [SnippetCatalog.Entry],
        installedPluginIDs: Set<String>
    ) async throws {
        switch content {
        case let .workflow(workflow, category):
            workflows.append(WorkflowCatalog.Entry(
                workflow: workflow,
                category: category
            ))
        case let .skeletonTemplate(workflow, name, summary, category):
            skeletons.append(SkeletonTemplateCatalog.Entry(
                name: name,
                summary: summary,
                category: category,
                workflow: workflow
            ))
        case let .jsPluginTool(bundleData, name):
            try await self.installPlugin(
                bundleData: bundleData,
                name: name,
                installedPluginIDs: installedPluginIDs
            )
        case let .promptSnippet(name, body, category):
            snippets.append(SnippetCatalog.Entry(
                name: name,
                body: body,
                category: category
            ))
        }
    }

    private func installPlugin(
        bundleData: Data,
        name: String,
        installedPluginIDs: Set<String>
    ) async throws {
        guard let installer = self.pluginInstaller else {
            return
        }
        if installedPluginIDs.contains(name) {
            return
        }
        try await installer.install(bundleData: bundleData)
    }
}

// MARK: - WorkflowRemixer

/// Pure-function helpers for the Remix flow. Lives in
/// `WorkflowKit` so both the chat-side workflow library and
/// the workflow editor can use the same semantics — duplicate
/// the catalogue entry, generate a fresh id, link back via
/// `parentWorkflowID`, and tag the name with a "(remix)"
/// suffix so the user can find it in the library.
public enum WorkflowRemixer {
    // MARK: Public

    /// Build a remix of `source` with a new id. Pure — the
    /// caller is responsible for persisting via `WorkflowStore`.
    public static func remix(_ source: Workflow, now: Date = Date()) -> Workflow {
        var copy = source
        copy = Workflow(
            id: UUID(),
            name: Self.remixName(source.name),
            summary: source.summary,
            inputSchema: source.inputSchema,
            outputSchema: source.outputSchema,
            nodes: source.nodes,
            edges: source.edges,
            triggers: source.triggers,
            modelHint: source.modelHint,
            toolPolicy: source.toolPolicy,
            memoryPolicy: source.memoryPolicy,
            createdAt: now,
            updatedAt: now,
            nodePositions: source.nodePositions,
            parentWorkflowID: source.id,
            timeOfDayTags: source.timeOfDayTags
        )
        return copy
    }

    // MARK: Internal

    /// Suffix the name with "(remix)" unless already present.
    /// Keeps the user's library visually distinct from the
    /// catalogue without polluting their custom names with
    /// repeated suffixes.
    static func remixName(_ original: String) -> String {
        if original.hasSuffix("(remix)") {
            return original
        }
        return "\(original) (remix)"
    }
}
