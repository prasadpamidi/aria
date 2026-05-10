#if canImport(AriaMLX)
import AriaMLX
import Foundation
import SwiftUI

// MARK: - MLXModelsSheet

/// Browses the curated MLX catalog, downloads / removes models from
/// the on-device Hugging Face cache, and surfaces per-model
/// capability metadata (tools, context window, RAM hint). Lives
/// behind the ContentView "Models…" menu item.
struct MLXModelsSheet: View {
    // MARK: Internal

    var body: some View {
        NavigationStack {
            List {
                Section("Catalog") {
                    ForEach(self.catalog, id: \.id) { entry in
                        ModelRow(
                            entry: entry,
                            disk: self.byID[entry.id],
                            isBusy: self.isBusy(entry.id),
                            onDownload: { Task { await self.download(entry) } },
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
    @State private var busyIDs: Set<String> = []
    @State private var errorMessage: String?

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

    private func isBusy(_ id: String) -> Bool {
        self.busyIDs.contains(id)
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
        self.busyIDs.insert(entry.id)
        defer { busyIDs.remove(entry.id) }
        do {
            _ = try await self.downloader.loadContainer(id: entry.id)
            await self.refresh()
        } catch {
            self.errorMessage = "Download failed: \(error)"
        }
    }

    @MainActor
    private func delete(_ id: String) async {
        do {
            try self.diskManager.remove(id: id)
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
    let isBusy: Bool
    let onDownload: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.entry.displayName).font(.body)
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
            HStack {
                Text(self.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                self.actionButton
            }
            .padding(.top, 2)
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
        if self.isBusy {
            ProgressView().controlSize(.small)
        } else if self.disk != nil {
            Button("Delete", role: .destructive, action: self.onDelete)
                .controlSize(.small)
                .buttonStyle(.bordered)
        } else {
            Button("Download", action: self.onDownload)
                .controlSize(.small)
                .buttonStyle(.bordered)
        }
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
#endif
