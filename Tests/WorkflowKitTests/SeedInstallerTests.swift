import Foundation
import Testing
@testable import WorkflowKit

// MARK: - SeedInstallerTests

/// Coverage for the catalogue installer's idempotency,
/// dispatch by content type, and the user-store ↔ catalogue
/// boundary. Catalog content is in-memory; user `WorkflowStore`
/// is touched only via Remix.
@MainActor
struct SeedInstallerTests {
    // MARK: Internal

    @Test
    func workflowsLandInCatalogNotInStore() async throws {
        // Prebuilt workflows live in the catalogue — the user's
        // `WorkflowStore` only holds user-authored content.
        let catalog = WorkflowCatalog()
        let installer = Self.makeInstaller(workflowCatalog: catalog)
        let workflow = Workflow(name: "Daily Brief")
        let source = StaticSource(contents: [.workflow(workflow, category: .dailyEssentials)])

        try await installer.installIfNeeded(sources: [source])

        #expect(catalog.entries.count == 1)
        #expect(catalog.entries.first?.workflow.id == workflow.id)
        #expect(catalog.entries.first?.category == .dailyEssentials)
    }

    @Test
    func reinstallReplacesCatalogWholesale() async throws {
        // Catalogue is rebuilt from scratch on each install pass
        // so v1.1 → v1.2 swaps don't pile up stale entries.
        let catalog = WorkflowCatalog()
        let installer = Self.makeInstaller(workflowCatalog: catalog)
        try await installer.installIfNeeded(sources: [
            StaticSource(contents: [.workflow(Workflow(name: "v1"), category: .dailyEssentials)]),
        ])
        try await installer.installIfNeeded(sources: [
            StaticSource(contents: [.workflow(Workflow(name: "v2"), category: .dailyEssentials)]),
        ])

        #expect(catalog.entries.count == 1)
        #expect(catalog.entries.first?.workflow.name == "v2")
    }

    @Test
    func userStoreIsUntouchedByInstaller() async throws {
        // The installer never writes to `WorkflowStore`. Remixes
        // are the only path that puts a workflow there.
        let store = try WorkflowStore()
        let installer = Self.makeInstaller()
        try await installer.installIfNeeded(sources: [
            StaticSource(contents: [.workflow(Workflow(name: "A"), category: .health)]),
        ])
        #expect(try store.list().isEmpty)
    }

    @Test
    func skeletonTemplatesPopulateCatalog() async throws {
        let skeletons = SkeletonTemplateCatalog()
        let installer = Self.makeInstaller(skeletonCatalog: skeletons)
        let template = Workflow(name: "Empty linear")
        let source = StaticSource(contents: [
            .skeletonTemplate(
                workflow: template,
                name: "Empty linear",
                summary: "LLM step + Output. The cheapest start.",
                category: .dailyEssentials
            ),
        ])
        try await installer.installIfNeeded(sources: [source])

        #expect(skeletons.entries.count == 1)
        #expect(skeletons.entries.first?.name == "Empty linear")
        #expect(skeletons.entries.first?.category == .dailyEssentials)
    }

    @Test
    func snippetsPublishedIntoCatalog() async throws {
        let snippets = SnippetCatalog()
        let installer = Self.makeInstaller(snippetCatalog: snippets)
        let source = StaticSource(contents: [
            .promptSnippet(name: "Summarize 3 bullets", body: "...", category: .summarize),
            .promptSnippet(name: "Translate to French", body: "...", category: .translate),
        ])
        try await installer.installIfNeeded(sources: [source])

        #expect(snippets.entries.count == 2)
        #expect(snippets.entries(in: .translate).count == 1)
    }

    @Test
    func pluginIDsAlreadyInstalledAreSkipped() async throws {
        let recorder = RecordingPluginInstaller(alreadyInstalled: ["weather"])
        let installer = Self.makeInstaller(pluginInstaller: recorder)
        let source = StaticSource(contents: [
            .jsPluginTool(bundleData: Data("{}".utf8), name: "weather"),
            .jsPluginTool(bundleData: Data("{}".utf8), name: "uuid"),
        ])
        try await installer.installIfNeeded(sources: [source])

        let installCount = await recorder.installCount()
        // "weather" was pre-installed → skipped. "uuid" was new → installed.
        #expect(installCount == 1)
    }

    // MARK: - Remix

    @Test
    func remixCopiesWorkflowWithFreshIDAndParentLink() {
        let original = Workflow(
            id: UUID(),
            name: "Daily Brief",
            summary: "Morning summary"
        )
        let remix = WorkflowRemixer.remix(original)
        #expect(remix.id != original.id)
        #expect(remix.parentWorkflowID == original.id)
        #expect(remix.name == "Daily Brief (remix)")
        #expect(remix.summary == original.summary)
    }

    @Test
    func remixDoesntDoubleSuffix() {
        // Avoid "Daily Brief (remix) (remix) (remix)" cascade
        // when the user remixes a remix.
        let already = Workflow(name: "Daily Brief (remix)")
        let again = WorkflowRemixer.remix(already)
        #expect(again.name == "Daily Brief (remix)")
    }

    @Test
    func parentWorkflowIDRoundTripsThroughCodable() throws {
        // The Remix link survives a JSON round-trip — that's
        // how the user's library knows "this is a remix of
        // catalogue entry X" across app launches.
        let parent = UUID()
        let workflow = Workflow(
            name: "X",
            parentWorkflowID: parent
        )
        let data = try JSONEncoder().encode(workflow)
        let decoded = try JSONDecoder().decode(Workflow.self, from: data)
        #expect(decoded.parentWorkflowID == parent)
    }

    // MARK: Private

    // MARK: - Helpers

    private static func makeInstaller(
        workflowCatalog: WorkflowCatalog = WorkflowCatalog(),
        skeletonCatalog: SkeletonTemplateCatalog = SkeletonTemplateCatalog(),
        snippetCatalog: SnippetCatalog = SnippetCatalog(),
        pluginInstaller: (any SeedPluginInstaller)? = nil
    ) -> SeedInstaller {
        SeedInstaller(
            workflowCatalog: workflowCatalog,
            skeletonCatalog: skeletonCatalog,
            snippetCatalog: snippetCatalog,
            pluginInstaller: pluginInstaller
        )
    }
}

// MARK: - StaticSource

private struct StaticSource: SeedContentSource {
    let contents: [SeedContent]
}

// MARK: - RecordingPluginInstaller

private actor RecordingPluginInstaller: SeedPluginInstaller {
    // MARK: Lifecycle

    init(alreadyInstalled: Set<String> = []) {
        self.alreadyInstalled = alreadyInstalled
    }

    // MARK: Internal

    func installedPluginIDs() async -> Set<String> {
        self.alreadyInstalled
    }

    func install(bundleData _: Data) async throws {
        self.installCalls += 1
    }

    func installCount() -> Int {
        self.installCalls
    }

    // MARK: Private

    private let alreadyInstalled: Set<String>
    private var installCalls = 0
}
