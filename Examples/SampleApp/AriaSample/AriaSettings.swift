import Foundation
import Observation
import SwiftUI

// MARK: - AriaSettings

/// User-tunable knobs that govern how the chat agent's middleware
/// chain is wired. Persisted to `UserDefaults` so a user's preferences
/// survive relaunch. Observable so `SettingsScreen` toggles drive
/// `ChatScreen`'s next agent build immediately.
///
/// Lives at the app level (one instance, shared across tabs) so a
/// summarization-trigger change in Settings is picked up on the next
/// chat turn without rewiring anything.
@MainActor
@Observable
final class AriaSettings {
    // MARK: Lifecycle

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.memoryEnabled = defaults.object(forKey: Keys.memoryEnabled) as? Bool ?? true
        self.summarizationEnabled = defaults.object(forKey: Keys.summarizationEnabled) as? Bool ?? true
        self.summarizationTriggerTurns = defaults.object(forKey: Keys.summarizationTrigger) as? Int ?? 8
        self.summarizationKeepRecentTurns = defaults.object(forKey: Keys.summarizationKeepRecent) as? Int ?? 4
        self.windowMaxTurns = defaults.object(forKey: Keys.windowMaxTurns) as? Int ?? 16
        self.windowMaxTokens = defaults.object(forKey: Keys.windowMaxTokens) as? Int ?? 4000
        self.factExtractionEnabled = defaults.object(forKey: Keys.factExtraction) as? Bool ?? true
        self.retentionMaxAgeDays = defaults.object(forKey: Keys.retentionAge) as? Int ?? 90
        self.retentionMaxThreads = defaults.object(forKey: Keys.retentionThreads) as? Int ?? 20
        self.ragTopK = defaults.object(forKey: Keys.ragTopK) as? Int ?? 4
    }

    // MARK: Internal

    /// Whether `RAGMiddleware` + `FactExtractionMiddleware` + the
    /// per-user memory namespace are wired at all. Off → no RAG, no
    /// auto-fact extraction, no remembered context across turns.
    var memoryEnabled: Bool {
        didSet { self.defaults.set(self.memoryEnabled, forKey: Keys.memoryEnabled) }
    }

    /// Whether `HistorySummarizationMiddleware` runs in the chain.
    /// Off → long threads still hit the window cap but lose the
    /// compressed summary of older turns.
    var summarizationEnabled: Bool {
        didSet { self.defaults.set(self.summarizationEnabled, forKey: Keys.summarizationEnabled) }
    }

    /// Non-system message count above which summarization fires.
    var summarizationTriggerTurns: Int {
        didSet { self.defaults.set(self.summarizationTriggerTurns, forKey: Keys.summarizationTrigger) }
    }

    /// How many recent non-system messages to keep verbatim (not
    /// summarized) when summarization fires.
    var summarizationKeepRecentTurns: Int {
        didSet { self.defaults.set(self.summarizationKeepRecentTurns, forKey: Keys.summarizationKeepRecent) }
    }

    /// `HistoryWindowMiddleware.maxTurns` — hard cap on non-system
    /// messages sent to the provider per step.
    var windowMaxTurns: Int {
        didSet { self.defaults.set(self.windowMaxTurns, forKey: Keys.windowMaxTurns) }
    }

    /// `HistoryWindowMiddleware.maxTokens` — token-budget cap using
    /// the default 4-chars-per-token heuristic.
    var windowMaxTokens: Int {
        didSet { self.defaults.set(self.windowMaxTokens, forKey: Keys.windowMaxTokens) }
    }

    /// Whether `FactExtractionMiddleware` runs in `afterStep` to
    /// mine durable user facts into the memory namespace.
    var factExtractionEnabled: Bool {
        didSet { self.defaults.set(self.factExtractionEnabled, forKey: Keys.factExtraction) }
    }

    /// `HistoryRetentionPolicy.maxThreadAgeDays`. Applied on app
    /// launch from `AriaSampleApp.init`.
    var retentionMaxAgeDays: Int {
        didSet { self.defaults.set(self.retentionMaxAgeDays, forKey: Keys.retentionAge) }
    }

    /// `HistoryRetentionPolicy.maxThreadCount`. Applied on app
    /// launch from `AriaSampleApp.init`.
    var retentionMaxThreads: Int {
        didSet { self.defaults.set(self.retentionMaxThreads, forKey: Keys.retentionThreads) }
    }

    /// `RAGMiddleware.topK` — how many memories to recall per turn.
    var ragTopK: Int {
        didSet { self.defaults.set(self.ragTopK, forKey: Keys.ragTopK) }
    }

    /// Reset every knob to the demo defaults. Useful when the user
    /// has tuned themselves into a corner and wants the suggested
    /// starting point back.
    func resetToDefaults() {
        self.memoryEnabled = true
        self.summarizationEnabled = true
        self.summarizationTriggerTurns = 8
        self.summarizationKeepRecentTurns = 4
        self.windowMaxTurns = 16
        self.windowMaxTokens = 4000
        self.factExtractionEnabled = true
        self.retentionMaxAgeDays = 90
        self.retentionMaxThreads = 20
        self.ragTopK = 4
    }

    // MARK: Private

    private enum Keys {
        static let memoryEnabled = "aria.sample.memory.enabled"
        static let summarizationEnabled = "aria.sample.summarization.enabled"
        static let summarizationTrigger = "aria.sample.summarization.trigger"
        static let summarizationKeepRecent = "aria.sample.summarization.keep"
        static let windowMaxTurns = "aria.sample.window.maxTurns"
        static let windowMaxTokens = "aria.sample.window.maxTokens"
        static let factExtraction = "aria.sample.factExtraction.enabled"
        static let retentionAge = "aria.sample.retention.ageDays"
        static let retentionThreads = "aria.sample.retention.maxThreads"
        static let ragTopK = "aria.sample.rag.topK"
    }

    private let defaults: UserDefaults
}

// MARK: - EnvironmentKey

private struct AriaSettingsKey: EnvironmentKey {
    @MainActor
    static var defaultValue: AriaSettings { AriaSettings() }
}

extension EnvironmentValues {
    /// Settings the chat agent reads on each build. Injected at the
    /// root so any screen can read or mutate without prop-drilling.
    var ariaSettings: AriaSettings {
        get { self[AriaSettingsKey.self] }
        set { self[AriaSettingsKey.self] = newValue }
    }
}
