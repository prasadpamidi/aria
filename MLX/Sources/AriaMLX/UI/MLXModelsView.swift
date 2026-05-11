#if canImport(MLXLMCommon) && canImport(SwiftUI)
    import Foundation
    import SwiftUI

    // MARK: - MLXModelsView

    /// A drop-in SwiftUI view that browses the catalog, downloads /
    /// removes models, surfaces live download progress, and lets the
    /// user pick the active model the agent will route through.
    ///
    /// Apps that want a different look-and-feel can ignore this view
    /// and build their own UI on top of `MLXModelManager`'s
    /// `Observable` surface (catalog, activeModelID, downloadProgress
    /// stream, downloadedModels list, remove). The headless API and
    /// the provided UI are designed to compose, not replace each
    /// other.
    public struct MLXModelsView: View {
        // MARK: Lifecycle

        public init(manager: MLXModelManager) {
            self.manager = manager
        }

        // MARK: Public

        public var body: some View {
            List {
                Section("Active provider") {
                    ActiveProviderRow(manager: self.manager)
                }
                self.catalogSection
                self.unknownSection
            }
            .task { await self.refresh() }
            .alert(self.errorMessage ?? "", isPresented: self.errorBinding) {
                Button("OK", role: .cancel) { }
            }
            .refreshable { await self.refresh() }
        }

        // MARK: Internal

        // MARK: Internal — bound to the SDK's manager

        @Bindable var manager: MLXModelManager

        // MARK: Private

        /// HubClient ticks every ~100 ms; 30 ticks = ~3 s without
        /// any change to `completedUnitCount`.
        private static let stallTickThreshold = 30

        @State private var diskEntries: [MLXDiskModel] = []
        @State private var progressByID: [String: DownloadDisplay] = [:]
        @State private var errorMessage: String?

        private var byID: [String: MLXDiskModel] {
            Dictionary(uniqueKeysWithValues: self.diskEntries.map { ($0.id, $0) })
        }

        private var unknownDiskEntries: [MLXDiskModel] {
            let curatedIDs = Set(self.manager.catalog.map(\.id))
            return self.diskEntries.filter { !curatedIDs.contains($0.id) }
        }

        private var errorBinding: Binding<Bool> {
            Binding(
                get: { self.errorMessage != nil },
                set: { if !$0 {
                    self.errorMessage = nil
                } }
            )
        }

        private var catalogSection: some View {
            Section("Catalog") {
                ForEach(self.manager.catalog, id: \.id) { entry in
                    CatalogRow(
                        entry: entry,
                        manager: self.manager,
                        disk: self.byID[entry.id],
                        progress: self.progressByID[entry.id],
                        onDownload: { Task { await self.download(entry) } },
                        onUse: { self.manager.setActiveModel(id: entry.id) },
                        onDelete: { Task { await self.remove(id: entry.id) } }
                    )
                }
            }
        }

        @ViewBuilder private var unknownSection: some View {
            if !self.unknownDiskEntries.isEmpty {
                Section("Other downloaded") {
                    ForEach(self.unknownDiskEntries, id: \.id) { disk in
                        UnknownRow(
                            disk: disk,
                            onDelete: { Task { await self.remove(id: disk.id) } }
                        )
                    }
                }
            }
        }

        @MainActor
        private func refresh() async {
            do {
                self.diskEntries = try self.manager.downloadedModels()
            } catch {
                self.errorMessage = "Could not list models: \(error)"
            }
        }

        @MainActor
        private func download(_ entry: MLXModelCapabilities) async {
            self.progressByID[entry.id] = DownloadDisplay.starting()
            defer { progressByID[entry.id] = nil }
            do {
                // HubClient sends ticks ~10/sec via its sampling task,
                // but the Xet transport only updates `completedUnitCount`
                // when each large file finishes — so the bar plateaus
                // for minutes between visible jumps. Count consecutive
                // ticks with no byte movement and flip to "stalled"
                // (indeterminate spinner) once we've gone ~3 s
                // without progress, so the UI doesn't look frozen.
                var stallTicks = 0
                var lastCompleted: Int64 = -1
                for try await tick in self.manager.downloadProgress(for: entry.id) {
                    if tick.completed > lastCompleted {
                        stallTicks = 0
                        lastCompleted = tick.completed
                    } else {
                        stallTicks += 1
                    }
                    self.progressByID[entry.id] = DownloadDisplay(
                        progress: tick,
                        isStalled: stallTicks >= Self.stallTickThreshold
                    )
                }
                await self.refresh()
            } catch {
                self.errorMessage = "Download failed: \(error)"
            }
        }

        @MainActor
        private func remove(id: String) async {
            do {
                try await self.manager.remove(id: id)
                await self.refresh()
            } catch {
                self.errorMessage = "Delete failed: \(error)"
            }
        }
    }

    // MARK: - DownloadDisplay

    /// One progress tick paired with whether the byte counter has
    /// been frozen long enough to count as "stalled" (HubClient's
    /// Xet transport only updates progress when each large file
    /// completes, so the bar can sit at the same byte count for
    /// minutes during the bulk of the download).
    private struct DownloadDisplay: Hashable {
        let progress: MLXDownloadProgress
        let isStalled: Bool

        static func starting() -> DownloadDisplay {
            DownloadDisplay(
                progress: MLXDownloadProgress(
                    completed: 0,
                    total: nil,
                    fraction: nil
                ),
                isStalled: false
            )
        }
    }

    // MARK: - ActiveProviderRow

    private struct ActiveProviderRow: View {
        // MARK: Internal

        @Bindable var manager: MLXModelManager

        var body: some View {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.title).font(.body)
                    Text(self.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if self.manager.activeModelID != nil {
                    Button("Use FoundationModels") {
                        self.manager.setActiveModel(id: nil)
                    }
                    .controlSize(.small).buttonStyle(.bordered)
                }
            }
        }

        // MARK: Private

        private var title: String {
            self.manager.activeCapabilities?.displayName ?? "FoundationModels (default)"
        }

        private var subtitle: String {
            self.manager.activeModelID == nil
                ? "Apple's on-device LLM"
                : "MLX, on-device"
        }
    }

    // MARK: - CatalogRow

    private struct CatalogRow: View {
        // MARK: Internal

        let entry: MLXModelCapabilities
        let manager: MLXModelManager
        let disk: MLXDiskModel?
        let progress: DownloadDisplay?
        let onDownload: () -> Void
        let onUse: () -> Void
        let onDelete: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(self.entry.displayName).font(.body)
                    if self.manager.activeModelID == self.entry.id {
                        Text("active")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                }
                self.badges
                if let progress {
                    self.progressRow(progress)
                } else {
                    self.statusRow
                }
            }
            .padding(.vertical, 6)
        }

        // MARK: Private

        private var statusText: String {
            if let disk {
                "Downloaded · \(format(bytes: disk.bytes))"
            } else {
                "Not downloaded · ~\(format(bytes: self.entry.approximateDiskBytes))"
            }
        }

        private var badges: some View {
            HStack(spacing: 8) {
                if self.entry.supportsTools {
                    Label("tools", systemImage: "wrench.and.screwdriver")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if self.entry.supportsVision {
                    Label("vision", systemImage: "eye")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("ctx \(self.entry.contextWindow)")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("≥\(self.entry.recommendedRAMGigabytes) GB RAM")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }

        private var statusRow: some View {
            HStack {
                Text(self.statusText)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                self.actionButton
            }
            .padding(.top, 2)
        }

        @ViewBuilder private var actionButton: some View {
            if self.disk != nil {
                HStack(spacing: 6) {
                    if self.manager.activeModelID != self.entry.id {
                        Button("Use", action: self.onUse)
                            .controlSize(.small).buttonStyle(.bordered)
                    }
                    Button("Delete", role: .destructive, action: self.onDelete)
                        .controlSize(.small).buttonStyle(.bordered)
                }
            } else {
                Button("Download", action: self.onDownload)
                    .controlSize(.small).buttonStyle(.bordered)
            }
        }

        private func progressRow(_ display: DownloadDisplay) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                if display.isStalled || display.progress.fraction == nil {
                    // Either total is unknown OR the byte counter
                    // hasn't moved in a while — show indeterminate
                    // motion so the bar doesn't look frozen.
                    ProgressView()
                } else if let fraction = display.progress.fraction {
                    ProgressView(value: fraction)
                }
                Text(progressLabel(display))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - UnknownRow

    private struct UnknownRow: View {
        let disk: MLXDiskModel
        let onDelete: () -> Void

        var body: some View {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.disk.id).font(.body).lineLimit(1)
                    Text(format(bytes: self.disk.bytes))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Delete", role: .destructive, action: self.onDelete)
                    .controlSize(.small).buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers

    private func format(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func progressLabel(_ display: DownloadDisplay) -> String {
        let progress = display.progress
        if display.isStalled {
            // HubClient's Xet transport doesn't surface byte-level
            // progress during the bulk of the download; tell the
            // user so a frozen counter doesn't read as a hang.
            return "Downloading… (no progress reported by Hub)"
        }
        if let fraction = progress.fraction, let total = progress.total {
            return "\(format(bytes: progress.completed)) / \(format(bytes: total)) "
                + "(\(Int(fraction * 100))%)"
        }
        if progress.completed > 0 {
            return "\(format(bytes: progress.completed)) downloaded"
        }
        return "Starting…"
    }

#endif
