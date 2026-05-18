import Aria
import AriaApple
import SwiftUI

#if canImport(AriaMLX)
    import AriaMLX
#endif

// MARK: - SettingsScreen

/// User-tunable settings backing the chat agent's middleware chain
/// plus app-level actions (model picker, share session, clear all).
/// Every toggle persists to `UserDefaults` via `AvyraSettings` and is
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
        sessionRecorder: SessionRecorder,
        activeThreadId: String = AvyraConstants.chatThreadId,
        onLoadThread: ((String) -> Void)? = nil
    ) {
        self.storage = storage
        self.appState = appState
        self.sessionRecorder = sessionRecorder
        self.activeThreadId = activeThreadId
        self.onLoadThread = onLoadThread
    }

    // MARK: Internal

    var body: some View {
        Form {
            self.exploreSection
            self.providerSection
            self.personalizationSection
            self.privacySection
            self.memorySection
            self.historyWindowSection
            self.summarizationSection
            self.retentionSection
            self.sessionSection

            #if DEBUG
                self.developerSection
            #endif

            self.resetSection
            self.aboutSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        // Interactive drag-down dismisses the keyboard. Needed
        // because the Custom Instructions multi-line TextField
        // doesn't have a return-key submit (return inserts a
        // newline) so users had no way out of edit mode.
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .cancel) { self.dismiss() }
                    .fontWeight(.semibold)
            }
            // Explicit "Done" key on the keyboard so users can
            // dismiss without scrolling — common iOS pattern for
            // sheets with text input. Resolves focus through the
            // SwiftUI `@FocusState` binding instead of an
            // imperative UIKit `resignFirstResponder` jump.
            ToolbarItem(placement: .keyboard) {
                HStack {
                    Spacer()
                    Button("Done") {
                        self.customInstructionsFocused = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .sheet(item: self.$shareItem) { item in
            ShareSheet(items: [item.url])
        }
        // Same model picker the chat header opens, so the user sees
        // one consistent surface no matter where they entered from.
        .sheet(isPresented: self.$modelPickerShown) {
            ModelPickerSheet(appState: self.appState) {
                self.modelPickerShown = false
            }
            .presentationDetents([.medium, .large])
        }
        .alert("Cleared", isPresented: self.$clearedConfirmation) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(self.clearedMessage)
        }
    }

    // MARK: Private

    /// Marketing version + build number from the app bundle. Falls
    /// back to a sensible placeholder when reading the bundle fails
    /// (e.g. previews running outside a real app context).
    private static var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    @Environment(\.avyraSettings) private var settings

    @Environment(\.dismiss) private var dismiss
    @State private var shareItem: SessionShareItem?
    @State private var modelPickerShown = false
    @State private var clearedConfirmation = false
    @State private var clearedMessage = ""
    /// Focus binding for the Custom Instructions multi-line field
    /// so the keyboard toolbar's Done button can release the
    /// keyboard with `self.customInstructionsFocused = false`.
    @FocusState private var customInstructionsFocused: Bool

    private let storage: GRDBStorage
    private let appState: AppState
    private let sessionRecorder: SessionRecorder
    private let activeThreadId: String
    private let onLoadThread: ((String) -> Void)?

    private var activeProviderLabel: String {
        #if canImport(AriaMLX)
            if let capabilities = self.appState.modelManager.activeCapabilities {
                return capabilities.displayName
            }
        #endif
        return "FoundationModels"
    }

    // MARK: - Sections

    /// Top-level navigation rows for the things that used to be their
    /// own tabs (Memories, Demos) plus the new "Previous chats"
    /// destination. Surfaced as the first section so the user finds
    /// them right under the navigation title without having to scroll
    /// past the configuration knobs.
    private var exploreSection: some View {
        Section {
            NavigationLink {
                MemoriesScreen(
                    storage: self.storage,
                    namespace: AvyraConstants.memoryNamespace
                )
            } label: {
                Label("Memories", systemImage: "brain.head.profile")
            }
            NavigationLink {
                PreviousChatsScreen(
                    storage: self.storage,
                    activeThreadId: self.activeThreadId,
                    onPick: { threadId in
                        self.onLoadThread?(threadId)
                        self.dismiss()
                    }
                )
            } label: {
                Label("Previous chats", systemImage: "bubble.left.and.bubble.right")
            }

            if self.settings.developerModeEnabled {
                NavigationLink {
                    DemosScreen(
                        storage: self.storage,
                        sessionRecorder: self.sessionRecorder
                    )
                } label: {
                    Label("Demos", systemImage: "sparkles")
                }
            }
        } header: {
            Text("Explore")
        } footer: {
            Text("Browse memories Avyra has stored, resume a past chat.")
        }
    }

    private var providerSection: some View {
        Section {
            HStack {
                Image(systemName: "cpu")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Active model")
                    Text(self.activeProviderLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                self.modelPickerShown = true
            } label: {
                HStack {
                    Label("Manage models", systemImage: "shippingbox")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("Model")
        } footer: {
            Text(
                "Avyra uses Apple Intelligence by default. Download and switch to an open-weight model from Manage models — your choice persists across launches."
            )
        }
    }

    /// Privacy toggles. Currently a single switch: whether new chats
    /// persist to disk. Existing persisted threads stay browsable
    /// either way — turning this off only stops *future* writes.
    /// User-controlled tuning for how the model should behave —
    /// custom instructions (persona/tone/preferences appended to the
    /// system prompt every turn) and sampling temperature. Both
    /// apply across all models since they affect the prompt + the
    /// generator, not the model itself.
    private var personalizationSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Custom instructions")
                    .font(.subheadline.weight(.medium))
                TextField(
                    "Tell Avyra how to behave — persona, tone, language preferences, persistent context.",
                    text: Bindable(self.settings).customInstructions,
                    axis: .vertical
                )
                .lineLimit(3...8)
                .textInputAutocapitalization(.sentences)
                .font(.body)
                .focused(self.$customInstructionsFocused)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Creativity")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(Self.temperatureLabel(self.settings.temperature))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Bindable(self.settings).temperature,
                    in: 0.0...1.5,
                    step: 0.05
                ) {
                    Text("Temperature")
                } minimumValueLabel: {
                    Text("Precise")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("Wild")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Personalization")
        } footer: {
            Text(
                "Custom instructions are added to the system prompt every turn. Creativity controls sampling temperature — lower is more deterministic, higher is more inventive."
            )
        }
    }

    private var privacySection: some View {
        Section {
            Toggle(
                "Save conversations on this device",
                isOn: Bindable(self.settings).persistConversationsEnabled
            )
        } header: {
            Text("Privacy")
        } footer: {
            if self.settings.persistConversationsEnabled {
                Text(
                    "Conversations are saved to this device so you can resume them later. Avyra never sends them to a server."
                )
            } else {
                Text(
                    "New conversations stay in memory and disappear when you quit Avyra. Previous chats remain available — open Previous chats to delete them."
                )
            }
        }
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

    /// Developer-only chrome the chat bubbles surface. Off by default
    /// — a non-technical user shouldn't see "Recalled 4 memories" or
    /// "remember_fact" tool pills above the assistant's reply.
    /// Thinking content (`<think>…</think>`) is always visible since
    /// that's UX transparency about the model itself, not internal
    /// plumbing.
    private var developerSection: some View {
        Section {
            Toggle("Developer mode", isOn: Bindable(self.settings).developerModeEnabled)
        } header: {
            Text("Developer")
        } footer: {
            Text("Surfaces under-the-hood signals on assistant messages: tool calls the agent fired, " +
                "and the recalled-memories chip from RAG. Reasoning (`<think>` blocks) is shown either way.")
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
                "To clear memories, open Memories from the Explore section above.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Avyra")
                Spacer()
                Text(Self.appVersionString)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            HStack {
                Text("Aria SDK")
                Spacer()
                Text(AriaInfo.version)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }

            if self.settings.developerModeEnabled {
                Link(destination: URL(string: "https://github.com/prasadpamidi/aria")!) {
                    Label("aria on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
    }

    /// "0.7 · Balanced" — humanizes the raw float for the slider
    /// readout so it isn't an opaque number.
    private static func temperatureLabel(_ value: Double) -> String {
        let bucket =
            switch value {
            case ..<0.2: "Deterministic"
            case ..<0.5: "Precise"
            case ..<0.85: "Balanced"
            case ..<1.15: "Creative"
            default: "Wild"
            }
        return String(format: "%.2f · %@", value, bucket)
    }

    private static func writeBundleToTempFile(_ bundle: SessionBundle) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bundle)
        let filename = "avyra-session-\(bundle.id).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    @MainActor
    private func clearChat() async {
        do {
            try await self.storage.chatHistory.clear(threadId: self.activeThreadId)
            self.clearedMessage = "Current chat history cleared."
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
}
