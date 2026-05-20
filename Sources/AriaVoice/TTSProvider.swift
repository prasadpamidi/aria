#if canImport(AVFoundation)
    import AVFoundation
    import Foundation

    // MARK: - TTSProvider

    /// Speak text aloud, optionally surfacing per-frame level samples so
    /// a voice-mode waveform can animate to the speech.
    ///
    /// The protocol intentionally hides the choice of synth engine so
    /// consumers can swap `AppleTTSProvider` (built-in
    /// `AVSpeechSynthesizer`) for `AriaVoiceKokoro.KokoroTTSProvider`
    /// (on-device MLX-Kokoro) or any custom backend without touching
    /// the voice controller or UI. Both produce the same observable
    /// shape: a stream of normalized levels that ends when playback is
    /// done.
    ///
    /// Levels are normalized to `0...1`. Sources that don't expose real
    /// audio metering (like `AVSpeechSynthesizer.speak`) may approximate
    /// with a synthetic pattern keyed to word boundaries — accurate
    /// enough to drive a visual waveform.
    public protocol TTSProvider: Sendable {
        /// Begin speaking the given text. Returns a stream that yields
        /// normalized level samples (`0...1`) at roughly 30 Hz while
        /// playback is in progress, and finishes when the utterance
        /// completes (or throws if synthesis fails).
        ///
        /// Caller must consume the stream to drive the waveform; not
        /// consuming it does not pause playback — the underlying synth
        /// is fire-and-forget by design.
        func speak(_ text: String) -> AsyncThrowingStream<Float, any Error>

        /// Cancel any in-flight speech immediately. Idempotent.
        func cancel() async
    }

    // MARK: - AppleTTSProvider

    /// `AVSpeechSynthesizer`-backed implementation. Ships zero new
    /// dependencies, uses Apple's bundled voices, supports every locale
    /// the device has. Voice quality is the OS default — fine for the
    /// first cut; consumers that want a higher-quality voice can swap
    /// in `KokoroTTSProvider` from AriaVoiceKokoro.
    ///
    /// **Level synthesis.** `AVSpeechSynthesizer.speak` doesn't expose
    /// audio metering, so we generate a pseudo-random level pattern at
    /// 30 Hz while the utterance is in flight (start→finish delegate
    /// callbacks). For real RMS metering, route through `AVAudioEngine`
    /// (as `KokoroTTSProvider` does).
    public final class AppleTTSProvider:
    NSObject, TTSProvider, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        // MARK: Lifecycle

        public override init() {
            super.init()
            self.synthesizer.delegate = self
        }

        // MARK: Public

        // MARK: TTSProvider

        public func speak(_ text: String) -> AsyncThrowingStream<Float, any Error> {
            AsyncThrowingStream { continuation in
                // Stash the continuation on the actor-isolated state so
                // delegate callbacks can finish/yield against it.
                Task { @MainActor in
                    self.currentContinuation = continuation
                    self.startLevelTicker()

                    let utterance = AVSpeechUtterance(string: text)
                    utterance.voice = self.preferredVoice()
                    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
                    utterance.pitchMultiplier = 1.0
                    utterance.volume = 1.0
                    self.activeUtterance = utterance
                    self.synthesizer.speak(utterance)
                }
            }
        }

        public func cancel() async {
            await MainActor.run {
                self.cancelLevelTicker()
                if self.synthesizer.isSpeaking {
                    self.synthesizer.stopSpeaking(at: .immediate)
                }
                // Finish any pending continuation cleanly so the consumer
                // doesn't hang waiting for events that won't arrive.
                self.currentContinuation?.finish()
                self.currentContinuation = nil
                self.activeUtterance = nil
            }
        }

        // MARK: AVSpeechSynthesizerDelegate

        public nonisolated func speechSynthesizer(
            _: AVSpeechSynthesizer,
            didFinish _: AVSpeechUtterance
        ) {
            Task { @MainActor in
                self.cancelLevelTicker()
                self.currentContinuation?.yield(0)
                self.currentContinuation?.finish()
                self.currentContinuation = nil
                self.activeUtterance = nil
            }
        }

        public nonisolated func speechSynthesizer(
            _: AVSpeechSynthesizer,
            didCancel _: AVSpeechUtterance
        ) {
            Task { @MainActor in
                self.cancelLevelTicker()
                self.currentContinuation?.yield(0)
                self.currentContinuation?.finish()
                self.currentContinuation = nil
                self.activeUtterance = nil
            }
        }

        // MARK: Private

        private let synthesizer = AVSpeechSynthesizer()
        @MainActor private var currentContinuation:
            AsyncThrowingStream<Float, any Error>.Continuation?
        @MainActor private var activeUtterance: AVSpeechUtterance?
        @MainActor private var levelTicker: Task<Void, Never>?

        /// Prefer the highest-quality English voice on the device. If the
        /// user has installed an "Enhanced" or "Premium" voice, we use it;
        /// otherwise fall back to the default system voice.
        @MainActor
        private func preferredVoice() -> AVSpeechSynthesisVoice? {
            let englishVoices = AVSpeechSynthesisVoice.speechVoices()
                .filter { $0.language.hasPrefix("en") }
            // Premium > Enhanced > Default — `quality` is an enum where
            // higher rawValue means better quality on iOS 16+.
            let best = englishVoices.max { $0.quality.rawValue < $1.quality.rawValue }
            return best ?? AVSpeechSynthesisVoice(language: "en-US")
        }

        /// Drive the waveform with a synthetic level pattern while the
        /// utterance is in flight. Random oscillation in the 0.3–0.9
        /// band reads as "speaking" without faking specific phonemes.
        ///
        /// Why synthetic: `AVSpeechSynthesizer.speak` plays directly to
        /// the system audio output; there's no `AVAudioMixerNode` to tap.
        @MainActor
        private func startLevelTicker() {
            self.cancelLevelTicker()
            self.levelTicker = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    let level = Float.random(in: 0.35...0.85)
                    self?.currentContinuation?.yield(level)
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        }

        @MainActor
        private func cancelLevelTicker() {
            self.levelTicker?.cancel()
            self.levelTicker = nil
        }
    }
#endif
