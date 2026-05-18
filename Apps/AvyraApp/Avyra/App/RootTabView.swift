import Aria
import AriaApple
import SwiftUI

// MARK: - RootTabView

/// Single-screen root for the polished sample app. The earlier
/// 4-tab layout (Chat / Demos / Memories / Settings) collapsed into
/// a single chat surface; everything else — Settings, Memories,
/// Demos, Previous chats — lives one tap deep behind the chat's
/// bottom-bar Settings button.
///
/// The name is kept for git history / project file stability even
/// though there are no longer any tabs.
struct RootTabView: View {
    // MARK: Lifecycle

    init(storage: GRDBStorage) {
        self.storage = storage
    }

    // MARK: Internal

    var body: some View {
        ChatScreen(
            storage: self.storage,
            appState: self.appState,
            sessionRecorder: self.sessionRecorder
        )
        .environment(self.settings)
    }

    // MARK: Private

    @State private var appState = AppState()
    @State private var settings = AvyraSettings()
    /// One recorder shared across every agent call in this app launch so
    /// "Share session…" inside Settings exports the full picture.
    @State private var sessionRecorder = SessionRecorder()

    private let storage: GRDBStorage
}

// MARK: - AvyraConstants

/// One source of truth for the per-app namespaces / thread ids.
enum AvyraConstants {
    /// Default thread id assigned to a brand-new chat. Each "new chat"
    /// action mints a fresh UUID-prefixed id, so this constant is only
    /// used as a stable seed for ad-hoc references (Settings clear
    /// affordance, retention policy starting point).
    static let chatThreadId = "default"

    /// Per-user memory namespace used by `RAGMiddleware` /
    /// `FactExtractionMiddleware` / the `RememberTool`.
    static let memoryNamespace = ["sample", "default"]
}
