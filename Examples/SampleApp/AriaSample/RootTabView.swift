import Aria
import AriaApple
import SwiftUI

// MARK: - RootTabView

/// Top-level navigation for the polished sample app. Four tabs
/// covering the surface a real user-facing Aria app would have:
///
///  - **Chat** — the primary conversational surface
///  - **Demos** — focused single-screen demos of structured output
///    and state-graph orchestration
///  - **Memories** — browse / curate what Aria has remembered about
///    the user
///  - **Settings** — tune the middleware chain knobs that govern
///    every chat turn
///
/// All four screens share the same `GRDBStorage`, `AppState`, and
/// `AriaSettings` so changes in one immediately propagate (toggling
/// memory in Settings is visible on the next chat turn; clearing
/// memories in Memories drops the RAG recall on the next turn).
struct RootTabView: View {
    // MARK: Lifecycle

    init(storage: GRDBStorage) {
        self.storage = storage
    }

    // MARK: Internal

    var body: some View {
        TabView {
            Tab("Chat", systemImage: "bubble.left.and.bubble.right") {
                NavigationStack {
                    ChatScreen(
                        storage: self.storage,
                        appState: self.appState,
                        sessionRecorder: self.sessionRecorder
                    )
                }
            }
            Tab("Demos", systemImage: "sparkles") {
                NavigationStack {
                    DemosScreen(
                        storage: self.storage,
                        sessionRecorder: self.sessionRecorder
                    )
                }
            }
            Tab("Memories", systemImage: "brain.head.profile") {
                NavigationStack {
                    MemoriesScreen(
                        storage: self.storage,
                        namespace: AriaSampleConstants.memoryNamespace
                    )
                }
            }
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack {
                    SettingsScreen(
                        storage: self.storage,
                        appState: self.appState,
                        sessionRecorder: self.sessionRecorder
                    )
                }
            }
        }
        // iOS 26 Liquid Glass tab bar — minimizes to a translucent pill
        // on scroll-down so the chat surface gets the full vertical
        // space while reading, and snaps back on scroll-up. Matches
        // the polished tab-bar behavior new Apple apps adopted.
        .tabBarMinimizeBehavior(.onScrollDown)
        .environment(self.settings)
    }

    // MARK: Private

    private let storage: GRDBStorage
    @State private var appState = AppState()
    @State private var settings = AriaSettings()
    /// One recorder shared across Chat + Demos so a single "Share
    /// session…" tap in Settings exports a bundle covering everything
    /// the user ran this session.
    @State private var sessionRecorder = SessionRecorder()
}

// MARK: - AriaSampleConstants

/// One source of truth for the per-app namespaces / thread ids that
/// were scattered as `private static let` across the prior single-view
/// version. Keeping them here lets every screen agree on what the
/// chat is, where memories live, etc.
enum AriaSampleConstants {
    /// Chat thread id used by `HistoryMiddleware` to load + persist
    /// the conversation transcript.
    static let chatThreadId = "default"

    /// Per-user memory namespace used by `RAGMiddleware` /
    /// `FactExtractionMiddleware` / the `RememberTool`.
    static let memoryNamespace = ["sample", "default"]
}
