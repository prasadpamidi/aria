import Aria
import AriaApple
import SwiftData
import SwiftUI

@main
struct AriaSampleApp: App {
    // MARK: Lifecycle

    init() {
        let result = Self.loadStorage()
        self.storageResult = result
        // Bound chat-history disk growth across all threads — runs
        // once per launch, idempotent. Pair with the agent-side
        // `HistoryWindowMiddleware` / `HistorySummarizationMiddleware`
        // (which bound the wire side) for the full memory story.
        if case let .success(storage) = result {
            Task.detached(priority: .background) {
                let policy = HistoryRetentionPolicy(
                    maxThreadAgeDays: 90,
                    maxThreadCount: 20
                )
                _ = try? await policy.enforce(on: storage.chatHistory)
            }
        }
    }

    // MARK: Internal

    var body: some Scene {
        WindowGroup {
            self.rootView
        }
        .modelContainer(self.sharedModelContainer)
    }

    // MARK: Private

    private let storageResult: Result<GRDBStorage, any Error>

    private let sharedModelContainer: ModelContainer = {
        let schema = Schema([Item.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        // The Xcode template establishes this container; if it ever fails the
        // SwiftData side of the sample is unusable, but the Aria side keeps
        // working, so we degrade to in-memory rather than crashing.
        if let container = try? ModelContainer(for: schema, configurations: [configuration]) {
            return container
        }
        let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // swiftlint:disable:next force_try
        return try! ModelContainer(for: schema, configurations: [inMemory])
    }()

    @ViewBuilder private var rootView: some View {
        switch self.storageResult {
        case let .success(storage):
            ContentView(storage: storage)
        case let .failure(error):
            VStack(spacing: 12) {
                Text("Aria storage failed to initialize")
                    .font(.headline)
                Text(String(describing: error))
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    /// Open (or create) the Aria sample database in Application Support.
    /// Returned as a `Result` so the failure path stays in the UI rather
    /// than crashing the process.
    private static func loadStorage() -> Result<GRDBStorage, any Error> {
        Result {
            let supportURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let url = supportURL.appendingPathComponent("aria-sample.sqlite")
            return try GRDBStorage(url: url)
        }
    }
}
