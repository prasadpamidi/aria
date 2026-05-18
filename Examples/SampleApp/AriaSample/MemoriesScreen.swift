import Aria
import AriaApple
import SwiftUI

// MARK: - MemoriesScreen

/// Browse every memory the agent has written into the configured
/// namespace. Refactor of the prior modal `MemoriesSheet` into a
/// proper tab destination — swipe-to-delete on individual rows,
/// "Clear all" in the toolbar, refresh to re-read after a chat turn
/// adds something.
///
/// Pulls directly from `MemoryStore.list(namespace:limit:)` so the
/// view always shows every persisted item, not just the ones
/// `MemoryStore.recall(query:)` would surface for a probe.
struct MemoriesScreen: View {
    // MARK: Lifecycle

    init(storage: GRDBStorage, namespace: [String]) {
        self.storage = storage
        self.namespace = namespace
    }

    // MARK: Internal

    var body: some View {
        content
            .navigationTitle("Memories")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) {
                        Task { await self.clearAll() }
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .disabled(self.items.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await self.load() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
            .task { await self.load() }
            .refreshable { await self.load() }
    }

    // MARK: Private

    @State private var items: [MemoryItem] = []
    @State private var loadError: String?

    private let storage: GRDBStorage
    private let namespace: [String]

    @ViewBuilder
    private var content: some View {
        if let loadError {
            errorState(loadError)
        } else if self.items.isEmpty {
            self.emptyState
        } else {
            List {
                Section {
                    ForEach(self.items, id: \.id) { item in
                        MemoryRow(item: item)
                    }
                    .onDelete { offsets in
                        Task { await self.delete(at: offsets) }
                    }
                } footer: {
                    Text("\(self.items.count) item\(self.items.count == 1 ? "" : "s") in namespace " +
                        "/\(self.namespace.joined(separator: "/"))")
                        .font(.caption)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("No memories yet")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Tell the chat something durable about yourself — e.g. " +
                "\"remember I prefer metric units\" — and refresh.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("Could not load memories")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func delete(at offsets: IndexSet) async {
        guard let store = self.makeStore() else {
            self.loadError = "NLEmbedding unavailable on this device."
            return
        }
        let ids = offsets.map { self.items[$0].id }
        do {
            for id in ids {
                try await store.forget(id: id, namespace: self.namespace)
            }
            self.items.remove(atOffsets: offsets)
        } catch {
            self.loadError = "Delete failed: \(error)"
        }
    }

    @MainActor
    private func clearAll() async {
        guard let store = self.makeStore() else {
            self.loadError = "NLEmbedding unavailable on this device."
            return
        }
        let ids = self.items.map(\.id)
        do {
            for id in ids {
                try await store.forget(id: id, namespace: self.namespace)
            }
            self.items = []
        } catch {
            self.loadError = "Clear failed: \(error)"
        }
    }

    private func makeStore() -> (any MemoryStore)? {
        guard let embedder = NLEmbeddingEmbedder() else { return nil }
        let vectorStore = self.storage.vectorStore(dimensions: embedder.dimensions)
        return DefaultMemoryStore(embedder: embedder, store: vectorStore)
    }

    @MainActor
    private func load() async {
        guard let store = self.makeStore() else {
            self.loadError = "NLEmbedding unavailable on this device."
            return
        }
        do {
            self.items = try await store.list(namespace: self.namespace, limit: 200)
            self.loadError = nil
        } catch {
            self.loadError = String(describing: error)
        }
    }
}

// MARK: - MemoryRow

private struct MemoryRow: View {
    let item: MemoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(self.item.content)
                .font(.body)
            HStack(spacing: 8) {
                if let kind = self.kindLabel {
                    Label(kind, systemImage: "tag")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(Capsule())
                }
                Text(self.item.id)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
    }

    /// Surface the `kind` metadata `RememberTool` writes when set —
    /// gives a quick visual hint of what category each memory was
    /// stored under without expanding the row.
    private var kindLabel: String? {
        if case let .string(value) = self.item.metadata["kind"] {
            return value
        }
        return nil
    }
}
