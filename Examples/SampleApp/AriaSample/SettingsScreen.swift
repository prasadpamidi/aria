import Aria
import AriaApple
import SwiftUI

#if canImport(AriaMLX)
    import AriaMLX
#endif

// MARK: - SettingsScreen

/// User-tunable settings backing the chat agent's middleware chain
/// plus app-level actions (model picker, share session, clear all).
/// Every toggle persists to `UserDefaults` via `AriaSettings` and is
/// picked up on the next chat turn.
///
/// Sections roughly mirror the middleware chain so a user can map
/// what they see in the chat back to the knob that controls it:
///   - Provider — which LLM the chat hits
///   - Memory — RAG + auto-fact-extraction
///   - History window — hard cap the provider sees
///   - Summarization — compress old turns
///   - Retention — disk-side eviction (applied on launch)
///   - Session — share a recording of everything that ran today
///   - Reset — both the settings and the per-thread chat/memory
///     data, kept separate so a user can revert one without nuking
///     the other.
struct SettingsScreen: View {
    // MARK: Lifecycle

    init(
        storage: GRDBStorage,
        appState: AppState,
        sessionRecorder: SessionRecorder
    ) {
        self.storage = storage
        self.appState = appState
        self.sessionRecorder = sessionRecorder
    }

    // MARK: Internal

    var body: some View {
        Form {
            self.providerSection
            self.memorySection
            self.historyWindowSection
            self.summarizationSection
            self.retentionSection
            self.sessionSection
            self.resetSection
            self.aboutSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: self.$shareItem) { item in
            ShareSheet(items: [item.url])
        }
        #if canImport(AriaMLX)
            .sheet(isPresented: self.$mlxModelsSheetShown) {
                NavigationStack {
                    MLXModelsView(manager: self.appState.modelManager)
                        .navigationTitle("MLX Models")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        #endif
        .alert("Cleared", isPresented: self.$clearedConfirmation) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(self.clearedMessage)
        }
    }

    // MARK: Private

    @Environment(\.ariaSettings) private var settings
    @State private var shareItem: SessionShareItem?
    @State private var mlxModelsSheetShown = false
    @State private var clearedConfirmation = false
    @State private var clearedMessage = ""

    private let storage: GRDBStorage
    private let appState: AppState
    private let sessionRecorder: SessionRecorder

    // MARK: - Sections

    private var providerSection: some View {
        Section {
            HStack {
                Image(systemName: "cpu")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Active provider")
                    Text(self.activeProviderLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            #if canImport(AriaMLX)
                Button {
                    self.mlxModelsSheetShown = true
                } label: {
                    HStack {
                        Label("MLX models", systemImage: "shippingbox")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            #endif
        } header: {
            Text("Provider")
        } footer: {
            Text("Chat uses FoundationModels (3B on-device) by default. " +
                "Pick an MLX model above to swap providers; the choice persists across launches.")
        }
    }

    private var activeProviderLabel: String {
        #if canImport(AriaMLX)
            if let capabilities = self.appState.modelManager.activeCapabilities {
                return capabilities.displayName
            }
        #endif
        return "FoundationModels"
    }

    private var memorySection: some View {
        Section {
            Toggle("Per-user memory", isOn: Bindable(self.settings).memoryEnabled)
            if self.settings.memoryEnabled {
                Stepper(
                    "Recall top-K memories: \(self.settings.ragTopK)",
                    value: Bindable(self.settings).ragTopK,
                    in: 1...10
                )
                Toggle("Auto-extract user facts", isOn: Bindable(self.settings).factExtractionEnabled)
            }
        } header: {
            Text("Memory")
        } footer: {
            Text("When on, the chat agent recalls the top-K relevant memories per turn (RAGMiddleware) " +
                "and auto-mines durable facts from each user message (FactExtractionMiddleware). " +
                "When off, the chat has no cross-turn memory beyond the immediate transcript.")
        }
    }

    private var historyWindowSection: some View {
        Section {
            Stepper(
                "Max turns: \(self.settings.windowMaxTurns)",
                value: Bindable(self.settings).windowMaxTurns,
                in: 4...64,
                step: 2
            )
            Stepper(
                "Max tokens: \(self.settings.windowMaxTokens)",
                value: Bindable(self.settings).windowMaxTokens,
                in: 1000...16000,
                step: 500
            )
        } header: {
            Text("History window")
        } footer: {
            Text("HistoryWindowMiddleware caps the message slice the provider sees per step. " +
                "Whichever cap bites first wins. Tokens are estimated at 4 chars/token.")
        }
    }

    private var summarizationSection: some View {
        Section {
            Toggle("Summarize older turns", isOn: Bindable(self.settings).summarizationEnabled)
            if self.settings.summarizationEnabled {
                Stepper(
                    "Trigger after \(self.settings.summarizationTriggerTurns) turns",
                    value: Bindable(self.settings).summarizationTriggerTurns,
                    in: 4...64,
                    step: 2
                )
                Stepper(
                    "Keep last \(self.settings.summarizationKeepRecentTurns) verbatim",
                    value: Bindable(self.settings).summarizationKeepRecentTurns,
                    in: 2...32
                )
            }
        } header: {
            Text("Summarization")
        } footer: {
            Text("HistorySummarizationMiddleware compresses the older portion of the thread into a " +
                "single system message once the trigger is reached, keeping the recent turns verbatim. " +
                "Uses a cheap on-device FoundationModels call.")
        }
    }

    private var retentionSection: some View {
        Section {
            Stepper(
                "Max thread age: \(self.settings.retentionMaxAgeDays) days",
                value: Bindable(self.settings).retentionMaxAgeDays,
                in: 7...365,
                step: 7
            )
            Stepper(
                "Max threads: \(self.settings.retentionMaxThreads)",
                value: Bindable(self.settings).retentionMaxThreads,
                in: 5...100,
                step: 5
            )
        } header: {
            Text("Retention")
        } footer: {
            Text("HistoryRetentionPolicy bounds disk growth by evicting whole threads. Applied " +
                "once on launch. Changes here take effect on next app launch.")
        }
    }

    private var sessionSection: some View {
        Section {
            Button {
                Task { await self.exportSession() }
            } label: {
                Label("Share session…", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("Session")
        } footer: {
            Text("Exports every agent run + state-graph transition from this app launch as a " +
                "Codable SessionBundle JSON. Replayable against a fresh agent for regression tests.")
        }
    }

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                self.settings.resetToDefaults()
            } label: {
                Label("Reset settings to defaults", systemImage: "arrow.counterclockwise")
            }
            Button(role: .destructive) {
                Task { await self.clearChat() }
            } label: {
                Label("Clear chat history", systemImage: "trash")
            }
        } header: {
            Text("Reset")
        } footer: {
            Text("Settings and chat are independent — resetting one doesn't touch the other. " +
                "To clear memories, use the Clear all action on the Memories tab.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Aria version")
                Spacer()
                Text(AriaInfo.version)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            Link(destination: URL(string: "https://github.com/prasadpamidi/aria")!) {
                Label("aria on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
    }

    // MARK: - Actions

    @MainActor
    private func clearChat() async {
        do {
            try await self.storage.chatHistory.clear(threadId: AriaSampleConstants.chatThreadId)
            self.clearedMessage = "Chat history cleared."
            self.clearedConfirmation = true
        } catch {
            self.clearedMessage = "Could not clear chat: \(error)"
            self.clearedConfirmation = true
        }
    }

    @MainActor
    private func exportSession() async {
        do {
            let bundle = await self.sessionRecorder.bundle()
            let url = try Self.writeBundleToTempFile(bundle)
            self.shareItem = SessionShareItem(url: url)
        } catch {
            self.clearedMessage = "Could not export session: \(error)"
            self.clearedConfirmation = true
        }
    }

    private static func writeBundleToTempFile(_ bundle: SessionBundle) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bundle)
        let filename = "aria-session-\(bundle.id).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }
}
