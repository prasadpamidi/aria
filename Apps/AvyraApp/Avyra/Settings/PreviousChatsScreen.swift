import Aria
import AriaApple
import SwiftUI

// MARK: - PreviousChatsScreen

/// Browses chat threads `HistoryMiddleware` has persisted to GRDB.
/// Each row shows the thread's first user message as a title and the
/// last message's age + message count as the subtitle, so users can
/// recognize a thread without having to open it.
///
/// Tap a thread → `onPick(threadId)` fires; the parent (`SettingsScreen`)
/// dismisses itself and the chat screen swaps its `currentThreadId` to
/// load that conversation.
///
/// Empty list → friendly placeholder. Errors → inline message; this
/// screen is read-only so a fetch failure isn't catastrophic.
struct PreviousChatsScreen: View {
    // MARK: Internal

    let storage: GRDBStorage
    let activeThreadId: String
    let onPick: (String) -> Void

    var body: some View {
        Group {
            switch self.loadState {
            case .loading:
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                self.emptyState
            case .ready:
                self.list
            case let .failed(message):
                self.failureState(message: message)
            }
        }
        .navigationTitle("Previous chats")
        .navigationBarTitleDisplayMode(.inline)
        .task { await self.reload() }
    }

    // MARK: Private

    @State private var threads: [ThreadSummary] = []
    @State private var loadState: LoadState = .loading
    @State private var pendingDeletion: ThreadSummary?
    @State private var confirmingDeleteAll = false
    @Environment(\.dismiss) private var dismiss

    private var list: some View {
        List {
            ForEach(self.threads) { thread in
                Button {
                    // Hand the thread up. The parent (`SettingsScreen`)
                    // owns the sheet dismissal — doing it here too
                    // would cause a double-dismiss / animation race
                    // and produce the abrupt transition we saw before.
                    self.onPick(thread.id)
                } label: {
                    self.row(thread)
                }
                .buttonStyle(.plain)
                .disabled(thread.id == self.activeThreadId)
                // Two ways to delete: native swipe-from-right for iOS
                // power users, long-press context menu for everyone
                // else. Both confirm via the destructive alert below
                // so an accidental tap can be cancelled.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        self.pendingDeletion = thread
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) {
                        self.pendingDeletion = thread
                    } label: {
                        Label("Delete conversation", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            if !self.threads.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            self.confirmingDeleteAll = true
                        } label: {
                            Label("Delete all", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .alert(
            "Delete this conversation?",
            isPresented: Binding(
                get: { self.pendingDeletion != nil },
                set: { if !$0 {
                    self.pendingDeletion = nil
                } }
            ),
            presenting: self.pendingDeletion
        ) { thread in
            Button("Delete", role: .destructive) {
                Task { await self.delete(thread: thread) }
            }
            Button("Cancel", role: .cancel) { self.pendingDeletion = nil }
        } message: { thread in
            Text("\"\(thread.title)\" will be removed from this device. This can't be undone.")
        }
        .alert(
            "Delete all conversations?",
            isPresented: self.$confirmingDeleteAll
        ) {
            Button("Delete All", role: .destructive) {
                Task { await self.deleteAll() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Every saved conversation will be removed from this device. This can't be undone.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("No previous chats")
                .font(.headline)
            Text("Conversations show up here once you've sent a message.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ thread: ThreadSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(thread.title)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    if thread.id == self.activeThreadId {
                        Text("Active")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(thread.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func failureState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Could not load")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try again") {
                Task { await self.reload() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func reload() async {
        self.loadState = .loading
        do {
            let ids = try await self.storage.chatHistory.threads()
            var summaries: [ThreadSummary] = []
            for id in ids {
                let messages = try await self.storage.chatHistory.messages(threadId: id)
                guard let summary = ThreadSummary(threadId: id, messages: messages) else {
                    continue
                }
                summaries.append(summary)
            }
            summaries.sort { $0.lastMessageAt > $1.lastMessageAt }
            self.threads = summaries
            self.loadState = summaries.isEmpty ? .empty : .ready
        } catch {
            self.loadState = .failed(String(describing: error))
        }
    }

    /// Remove a single thread from GRDB and the in-memory list.
    /// Animated so the row collapses in place — without that the
    /// deletion reads as a flash + reflow that loses the user's eye.
    @MainActor
    private func delete(thread: ThreadSummary) async {
        do {
            try await self.storage.chatHistory.clear(threadId: thread.id)
            withAnimation(.smooth) {
                self.threads.removeAll { $0.id == thread.id }
                if self.threads.isEmpty {
                    self.loadState = .empty
                }
            }
        } catch {
            self.loadState = .failed(String(describing: error))
        }
        self.pendingDeletion = nil
    }

    /// Nuke every persisted thread. Confirmation already happened in
    /// the alert; this just runs the loop.
    @MainActor
    private func deleteAll() async {
        let snapshot = self.threads
        for thread in snapshot {
            try? await self.storage.chatHistory.clear(threadId: thread.id)
        }
        withAnimation(.smooth) {
            self.threads = []
            self.loadState = .empty
        }
        self.confirmingDeleteAll = false
    }
}

// MARK: - ThreadSummary

private struct ThreadSummary: Identifiable {
    // MARK: Lifecycle

    init?(threadId: String, messages: [Message]) {
        guard !messages.isEmpty else {
            return nil
        }
        self.id = threadId

        let firstUser = messages.first { $0.role == .user }
        let raw = firstUser?.textContent ?? messages.first?.textContent ?? "Untitled chat"
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = cleaned.isEmpty ? "Untitled chat" : cleaned

        let last = messages.last
        let when = last?.createdAt ?? Date()
        self.lastMessageAt = when

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relative = formatter.localizedString(for: when, relativeTo: Date())
        self.subtitle = "\(messages.count) message\(messages.count == 1 ? "" : "s") · \(relative)"
    }

    // MARK: Internal

    let id: String
    let title: String
    let subtitle: String
    let lastMessageAt: Date
}

// MARK: - LoadState

private enum LoadState {
    case loading
    case empty
    case ready
    case failed(String)
}
