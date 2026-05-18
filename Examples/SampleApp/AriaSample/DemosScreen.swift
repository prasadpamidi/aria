import Aria
import AriaApple
import SwiftUI

#if canImport(FoundationModels)
    import FoundationModels
#endif

// MARK: - DemosScreen

/// List of focused single-screen demos. Each demo demonstrates one
/// Aria feature in isolation — what the chat tab uses end-to-end but
/// here teased apart so a reader of the sample can see each piece.
///
/// Today: structured output (`agent.respond(_:as:)`) and the
/// `StateGraph` haiku chain with checkpoint + resume. Add new demos
/// by appending to `DemoEntry.all`.
struct DemosScreen: View {
    // MARK: Lifecycle

    init(storage: GRDBStorage, sessionRecorder: SessionRecorder) {
        self.storage = storage
        self.sessionRecorder = sessionRecorder
    }

    // MARK: Internal

    var body: some View {
        List {
            ForEach(DemoEntry.all) { entry in
                NavigationLink {
                    self.destination(for: entry)
                } label: {
                    DemoRow(entry: entry)
                }
            }
        }
        .navigationTitle("Demos")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: Private

    private let storage: GRDBStorage
    private let sessionRecorder: SessionRecorder

    @ViewBuilder
    private func destination(for entry: DemoEntry) -> some View {
        switch entry.kind {
        case .suggestActivity:
            #if canImport(FoundationModels)
                if #available(iOS 26.0, macOS 26.0, *) {
                    SuggestActivityScreen()
                } else {
                    self.requiresIOS26
                }
            #else
                self.requiresIOS26
            #endif
        case .haikuChain:
            #if canImport(FoundationModels)
                if #available(iOS 26.0, macOS 26.0, *) {
                    HaikuChainScreen(
                        storage: self.storage,
                        sessionRecorder: self.sessionRecorder
                    )
                } else {
                    self.requiresIOS26
                }
            #else
                self.requiresIOS26
            #endif
        }
    }

    private var requiresIOS26: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Requires iOS 26 / macOS 26")
                .font(.headline)
            Text("This demo uses FoundationModels, which is iOS 26+.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }
}

// MARK: - DemoEntry

struct DemoEntry: Identifiable {
    enum Kind {
        case suggestActivity
        case haikuChain
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let systemImage: String

    static let all: [DemoEntry] = [
        DemoEntry(
            id: "suggest",
            kind: .suggestActivity,
            title: "Suggest activity",
            subtitle: "Structured output via agent.respond(_:as:)",
            systemImage: "lightbulb"
        ),
        DemoEntry(
            id: "haiku",
            kind: .haikuChain,
            title: "Haiku chain",
            subtitle: "StateGraph with checkpoint + resume",
            systemImage: "rectangle.connected.to.line.below"
        ),
    ]
}

// MARK: - DemoRow

struct DemoRow: View {
    let entry: DemoEntry

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: self.entry.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(self.entry.title)
                    .font(.headline)
                Text(self.entry.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
