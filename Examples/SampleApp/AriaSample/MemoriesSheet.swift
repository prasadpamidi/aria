import Aria
import AriaApple
import SwiftUI

// MARK: - MemoriesSheet

/// Presents every memory `RememberTool` has stored in the configured
/// namespace. Useful for verifying embeddings actually land in the
/// vector store and that retrieval is working end-to-end.
///
/// Pulls directly from `MemoryStore.list(namespace:limit:)` rather
/// than going through `recall(query:)`, so the sheet always shows
/// every persisted item, not just the ones similar to a probe query.
struct MemoriesSheet: View {
    // MARK: Lifecycle

    init(storage: GRDBStorage, namespace: [String]) {
        self.storage = storage
        self.namespace = namespace
    }

    // MARK: Internal

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Memories")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Clear all", role: .destructive) {
                            Task { await self.clearAll() }
                        }
                        .disabled(self.items.isEmpty)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Refresh") { Task { await self.load() } }
                    }
                }
                .task { await self.load() }
        }
    }

    // MARK: Private

    @State private var items: [MemoryItem] = []
    @State private var loadError: String?

    private let storage: GRDBStorage
    private let namespace: [String]

    @ViewBuilder private var content: some View {
        if let loadError {
            Text("Could not load: \(loadError)")
                .foregroundStyle(.secondary)
                .padding()
        } else if self.items.isEmpty {
            Text("No memories yet. Tell the chat something to remember "
                + "(e.g. \"Remember I prefer metric units\") and refresh.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding()
        } else {
            List {
                ForEach(self.items, id: \.id) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.content).font(.body)
                        Text(item.id).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { offsets in
                    Task { await self.delete(at: offsets) }
                }
            }
        }
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
        guard let embedder = NLEmbeddingEmbedder() else {
            return nil
        }
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
