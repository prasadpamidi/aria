#if canImport(OSLog)
    import OSLog

    /// Shared `Logger` for AriaVoice (STT, TTS, controller). All voice
    /// files write through this one channel so a single `log stream
    /// --predicate 'subsystem == "so.aria.voice"'` captures the full
    /// picture across the package.
    ///
    /// The subsystem is intentionally neutral — `so.aria.voice` rather
    /// than any app-specific bundle id — so consumer apps that include
    /// AriaVoice see a stable identifier in Console.app regardless of
    /// which app surfaces it. Apps that want their own subsystem can
    /// declare a separate `Logger` and ignore this one; logs are not
    /// routed through a single sink.
    public let voiceLog = Logger(
        subsystem: "so.aria.voice",
        category: "Voice"
    )
#endif
