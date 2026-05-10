#if canImport(AriaMLX)
    import AriaMLX
    import Foundation
    import SwiftUI

    // MARK: - MLXModelsSheet

    /// Browses the curated MLX catalog, downloads / removes models from
    /// the on-device Hugging Face cache, surfaces per-model capability
    /// metadata (tools, context window, RAM hint), and lets the user
    /// pick an active model so the chat agent can route through MLX
    /// instead of FoundationModels.
    struct MLXModelsSheet: View {
        // MARK: Lifecycle

        init(appState: AppState) {
            self.appState = appState
        }

        // MARK: Internal

        var body: some View {
            NavigationStack {
                List {
                    Section("Active provider") {
                        self.activeProviderRow
                    }
                    Section("Catalog") {
                        ForEach(self.catalog, id: \.id) { entry in
                            ModelRow(
                                entry: entry,
                                disk: self.byID[entry.id],
                                progress: self.progressByID[entry.id],
                                isActive: self.appState.selectedMLXModelID == entry.id,
                                onDownload: { Task { await self.download(entry) } },
                                onUse: { self.use(entry: entry) },
                                onDelete: { Task { await self.delete(entry.id) } }
                            )
                        }
                    }
                    if !self.unknownDiskEntries.isEmpty {
                        Section("Other downloaded") {
                            ForEach(self.unknownDiskEntries, id: \.id) { disk in
                                UnknownModelRow(
                                    disk: disk,
                                    onDelete: { Task { await self.delete(disk.id) } }
                                )
                            }
                        }
                    }
                }
                .navigationTitle("MLX Models")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Refresh") { Task { await self.refresh() } }
                    }
                }
                .task { await self.refresh() }
                .alert(self.errorMessage ?? "", isPresented: self.errorBinding) {
                    Button("OK", role: .cancel) {}
                }
            }
        }

        // MARK: Private

        @State private var diskEntries: [MLXDiskModel] = []
        @State private var progressByID: [String: MLXDownloadProgress] = [:]
        @State private var errorMessage: String?

        @Bindable private var appState: AppState

        private let downloader = MLXModelDownloader()
        private let diskManager = MLXModelDiskManager()
        private var catalog: [MLXModelCapabilities] { MLXModelCatalog.defaults }

        private var byID: [String: MLXDiskModel] {
            Dictionary(uniqueKeysWithValues: self.diskEntries.map { ($0.id, $0) })
        }

        private var unknownDiskEntries: [MLXDiskModel] {
            let curatedIDs = Set(self.catalog.map(\.id))
            return self.diskEntries.filter { !curatedIDs.contains($0.id) }
        }

        private var errorBinding: Binding<Bool> {
            Binding(
                get: { self.errorMessage != nil },
                set: { if !$0 { self.errorMessage = nil } }
            )
        }

        @ViewBuilder
        private var activeProviderRow: some View {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.activeProviderTitle)
                        .font(.body)
                    Text(self.activeProviderSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if self.appState.selectedMLXModelID != nil {
                    Button("Use FoundationModels") {
                        self.appState.selectedMLXModelID = nil
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            }
        }

        private var activeProviderTitle: String {
            if let id = self.appState.selectedMLXModelID {
                MLXModelCatalog.entry(for: id)?.displayName ?? id
            } else {
                "FoundationModels (default)"
            }
        }

        private var activeProviderSubtitle: String {
            if self.appState.selectedMLXModelID == nil {
                "Apple's on-device LLM"
            } else {
                "MLX, on-device"
            }
        }

        private func use(entry: MLXModelCapabilities) {
            self.appState.selectedMLXModelID = entry.id
        }

        @MainActor
        private func refresh() async {
            do {
                self.diskEntries = try self.diskManager.list()
            } catch {
                self.errorMessage = "Could not list models: \(error)"
            }
        }

        @MainActor
        private func download(_ entry: MLXModelCapabilities) async {
            self.progressByID[entry.id] = MLXDownloadProgress(
                completed: 0,
                total: nil,
                fraction: nil
            )
            defer { progressByID[entry.id] = nil }
            do {
                for try await tick in self.downloader.progressStream(id: entry.id) {
                    self.progressByID[entry.id] = tick
                }
                await self.refresh()
            } catch {
                self.errorMessage = "Download failed: \(error)"
            }
        }

        @MainActor
        private func delete(_ id: String) async {
            do {
                try self.diskManager.remove(id: id)
                if self.appState.selectedMLXModelID == id {
                    self.appState.selectedMLXModelID = nil
                }
                await self.refresh()
            } catch {
                self.errorMessage = "Delete failed: \(error)"
            }
        }
    }

    // MARK: - ModelRow

    private struct ModelRow: View {
        let entry: MLXModelCapabilities
        let disk: MLXDiskModel?
        let progress: MLXDownloadProgress?
        let isActive: Bool
        let onDownload: () -> Void
        let onUse: () -> Void
        let onDelete: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(self.entry.displayName).font(.body)
                    if self.isActive {
                        Text("active")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                }
                HStack(spacing: 8) {
                    if self.entry.supportsTools {
                        Label("tools", systemImage: "wrench.and.screwdriver")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("ctx \(self.entry.contextWindow)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("≥\(self.entry.recommendedRAMGigabytes) GB RAM")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let progress {
                    self.downloadProgressRow(progress)
                } else {
                    HStack {
                        Text(self.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        self.actionButton
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, 6)
        }

        private var statusText: String {
            if let disk {
                "Downloaded · \(format(bytes: disk.bytes))"
            } else {
                "Not downloaded · ~\(format(bytes: self.entry.approximateDiskBytes))"
            }
        }

        @ViewBuilder
        private var actionButton: some View {
            if self.disk != nil {
                HStack(spacing: 6) {
                    if !self.isActive {
                        Button("Use", action: self.onUse)
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                    }
                    Button("Delete", role: .destructive, action: self.onDelete)
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                }
            } else {
                Button("Download", action: self.onDownload)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
        }

        @ViewBuilder
        private func downloadProgressRow(_ progress: MLXDownloadProgress) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: progress.fraction ?? 0)
                Text(progressLabel(progress))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - UnknownModelRow

    private struct UnknownModelRow: View {
        let disk: MLXDiskModel
        let onDelete: () -> Void

        var body: some View {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.disk.id).font(.body).lineLimit(1)
                    Text(format(bytes: self.disk.bytes))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Delete", role: .destructive, action: self.onDelete)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
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

    private func progressLabel(_ progress: MLXDownloadProgress) -> String {
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
