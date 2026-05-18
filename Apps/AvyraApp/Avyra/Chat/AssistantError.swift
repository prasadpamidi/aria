import Foundation

// MARK: - AssistantError

/// What the chat bubble should show in place of a normal assistant
/// reply when the provider couldn't produce one. Splits a clean,
/// user-facing summary from the raw error dump so the bubble can
/// show one to non-technical users and the other (collapsed) only
/// when developer mode is on.
struct AssistantError: Equatable {
    // MARK: Lifecycle

    init(friendly: String, hint: String = "", technical: String) {
        self.friendly = friendly
        self.hint = hint
        self.technical = technical
    }

    // MARK: Internal

    /// One short sentence the user reads. Never includes Swift error
    /// case names, NSError keys, or stack traces.
    let friendly: String

    /// Optional second sentence — extra context when we can be more
    /// specific (e.g. "Apple Intelligence is busy. Try again in a
    /// moment."). Empty string when nothing useful to add.
    let hint: String

    /// The raw `String(describing: error)` dump. Hidden by default;
    /// surfaced in the bubble only when `developerModeEnabled`. Lets
    /// a developer copy + paste the full error for filing a bug.
    let technical: String
}

// MARK: - Error → AssistantError

extension AssistantError {
    /// Translate a raw `Error` from an Aria provider stream into
    /// something a user can act on. Recognizes a small set of common
    /// failure modes (FoundationModels, network, cancellation) and
    /// falls back to a generic "something went wrong" otherwise.
    ///
    /// Always preserves the raw description in `technical` so a
    /// developer running with Developer Mode on can copy the full
    /// chain for triage.
    static func from(_ error: Error) -> AssistantError {
        let raw = String(describing: error)
        let lower = raw.lowercased()

        // Network connectivity
        if lower.contains("not connected to the internet")
            || lower.contains("network connection was lost")
            || lower.contains("offline") {
            return AssistantError(
                friendly: "No internet connection.",
                hint: "Check your Wi-Fi or cellular and try again.",
                technical: raw
            )
        }

        // Apple's Sensitive Content Analysis classifier blocked
        // the request. Returned by FoundationModels as
        // `com.apple.SensitiveContentAnalysisML Code=15` nested
        // inside the LanguageModelSession.GenerationError chain.
        // The user couldn't have known; explain it clearly.
        if lower.contains("sensitivecontentanalysisml")
            || lower.contains("sensitivecontent") {
            return AssistantError(
                friendly: "Apple Intelligence won't respond to that.",
                hint: "Its safety classifier flagged the message. Try rephrasing, or switch to an open-weight model in Manage models if you need to discuss the topic.",
                technical: raw
            )
        }

        // Foundation Models specifics
        if lower.contains("foundationmodels") {
            if lower.contains("guardrail") || lower.contains("safety") {
                return AssistantError(
                    friendly: "Apple Intelligence couldn't help with that.",
                    hint: "Try rephrasing your message.",
                    technical: raw
                )
            }
            if lower.contains("unavailable") || lower.contains("not available") {
                return AssistantError(
                    friendly: "Apple Intelligence is unavailable right now.",
                    hint: "Make sure Apple Intelligence is enabled in Settings and try again.",
                    technical: raw
                )
            }
            if lower.contains("rate") || lower.contains("busy") || lower.contains("throttl") {
                return AssistantError(
                    friendly: "Apple Intelligence is busy.",
                    hint: "Try again in a moment.",
                    technical: raw
                )
            }
            return AssistantError(
                friendly: "Apple Intelligence couldn't finish that reply.",
                hint: "Please try again.",
                technical: raw
            )
        }

        // Cancellation — usually a user-initiated stop, no scary copy.
        if error is CancellationError || lower.contains("cancelled") {
            return AssistantError(
                friendly: "Response stopped.",
                hint: "",
                technical: raw
            )
        }

        // Gemma 2 (and a few other open models) enforce strict
        // user/assistant alternation via their chat template. When
        // any non-user/assistant message slips in (system prompt,
        // summarization-injected message, repeated user turn), the
        // template throws "Conversation roles must alternate…".
        // It's a model-side limitation we can't fix at the app
        // layer — suggest a model swap instead.
        if lower.contains("conversation roles must alternate")
            || lower.contains("roles must alternate") {
            return AssistantError(
                friendly: "This model has strict conversation rules.",
                hint: "Open Manage models and switch to Llama 3.2 or Qwen 3.5 — they're more flexible. The Gemma family is picky about how messages are ordered.",
                technical: raw
            )
        }

        // MLX / on-device LM failures
        if lower.contains("mlx") || lower.contains("model") && lower.contains("load") {
            return AssistantError(
                friendly: "Couldn't load the model.",
                hint: "Try switching to a smaller model or freeing up some storage.",
                technical: raw
            )
        }

        // Generic fallback
        return AssistantError(
            friendly: "Something went wrong.",
            hint: "Please try again.",
            technical: raw
        )
    }
}
