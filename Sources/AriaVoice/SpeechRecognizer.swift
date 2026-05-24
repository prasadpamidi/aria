// `AVAudioSession` is iOS-family only — macOS has Speech +
// AVFoundation but not session APIs. Restrict the file to the
// iOS-family OSes rather than the broader `canImport` check.
#if (os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)) && canImport(Speech) && canImport(AVFoundation)
    import AVFoundation
    import Foundation
    import OSLog
    import Speech

    // MARK: - SpeechRecognizer

    /// Live, on-device transcription with audio metering for the
    /// voice-mode waveform. Wraps `SFSpeechRecognizer` + `AVAudioEngine`
    /// behind a small `@Observable` shape so views can read the
    /// `transcript` / `inputLevel` properties directly.
    ///
    /// Lifecycle:
    ///   1. `requestPermissions()` — gates the mic + recognition prompts.
    ///      Resolves to `.authorized` or a granular denial reason.
    ///   2. `startListening()` — opens the engine + recognition task.
    ///      `transcript` updates as partials arrive, `inputLevel` updates
    ///      ~30 times a second from the mic tap.
    ///   3. `stopListening()` — ends the recognition task; flushes any
    ///      remaining partial as the final result.
    ///
    /// Silence detection: when `inputLevel` stays under `silenceThreshold`
    /// for `silenceWindow` and a non-empty transcript exists, the
    /// `onSilenceComplete` callback fires once. Callers use that to send
    /// the turn to the agent without making the user tap a button.
    @MainActor
    @Observable
    public final class SpeechRecognizer {
        // MARK: Lifecycle

        public init(
            locale: Locale = .current,
            silenceThreshold: Float = 0.05,
            silenceWindow: TimeInterval = 1.4,
            noSpeechTimeout: TimeInterval = 60
        ) {
            self.recognizer = SFSpeechRecognizer(locale: locale)
            self.silenceThreshold = silenceThreshold
            self.silenceWindow = silenceWindow
            self.noSpeechTimeout = noSpeechTimeout
        }

        deinit {
            // No-op: the engine teardown happens on `stopListening()`.
            // Allowing deinit to touch `@MainActor` state would violate
            // Swift 6 isolation; the controller above us is responsible
            // for cleaning up before going away.
        }

        // MARK: Public

        public enum Permission: Equatable, Sendable {
            case authorized
            case microphoneDenied
            case speechDenied
            case speechUnavailable
        }

        public enum VoiceRecognizerError: LocalizedError {
            case unavailable

            // MARK: Public

            public var errorDescription: String? {
                switch self {
                case .unavailable:
                    "Speech recognition isn't available right now. Check your network and language settings."
                }
            }
        }

        /// Latest accumulated transcript for the current listening session.
        /// Resets to `""` on each `startListening()`.
        public private(set) var transcript: String = ""

        /// Normalized mic input level (0...1), updated from the engine tap
        /// at ~30 Hz. Drives the waveform animation.
        public private(set) var inputLevel: Float = 0

        /// True between `startListening()` and the next `stopListening()`.
        public private(set) var isListening: Bool = false

        /// Ask the system for mic + speech recognition permissions. Safe
        /// to call repeatedly — once granted, the prompts don't re-fire.
        ///
        /// **Ordering note.** Typical callers invoke this from a view's
        /// `.task` modifier, which fires after the view appears but
        /// BEFORE any presenting `.fullScreenCover` transition has fully
        /// settled. Without guardrails the system permission alerts can
        /// overlap the presenting animation and feel like they fire "too
        /// soon."
        ///
        /// Fix: check the persisted authorization status first; only
        /// trigger the actual prompts when state is `.notDetermined`,
        /// and yield a small delay in that case so the cover finishes
        /// presenting before the alert renders. Returning users with
        /// existing grants hit the fast path with no delay.
        public func requestPermissions() async -> Permission {
            let t0 = Date()
            // Fast path: both already granted → no prompts, no delay.
            let cachedSpeech = SFSpeechRecognizer.authorizationStatus()
            let cachedMic = AVAudioApplication.shared.recordPermission
            voiceLog
                .info(
                    "[Voice/STT] requestPermissions cached: speech=\(String(describing: cachedSpeech), privacy: .public) mic=\(String(describing: cachedMic), privacy: .public) recognizer.isAvailable=\(self.recognizer?.isAvailable ?? false)"
                )
            if cachedSpeech == .authorized, cachedMic == .granted {
                guard let recognizer, recognizer.isAvailable else {
                    voiceLog
                        .error(
                            "[Voice/STT] permissions cached-authorized but recognizer unavailable (isAvailable=false) — returning .speechUnavailable"
                        )
                    return .speechUnavailable
                }
                voiceLog.info("[Voice/STT] permissions fast-path .authorized (t+\(Self.elapsed(from: t0))ms)")
                return .authorized
            }
            // First denial wins — surface it without firing the other
            // prompt at all, so a user who said no to mic doesn't also
            // get hit with the speech prompt.
            if cachedSpeech == .denied || cachedSpeech == .restricted {
                voiceLog.notice("[Voice/STT] cached speech denial — no prompts")
                return .speechDenied
            }
            if cachedMic == .denied {
                voiceLog.notice("[Voice/STT] cached mic denial — no prompts")
                return .microphoneDenied
            }

            // Need at least one prompt. A short pause lets the
            // fullScreenCover present and the spinner render before
            // the system alert overlays everything — without it the
            // alert can fire mid-transition and look glitchy.
            try? await Task.sleep(for: .milliseconds(150))

            // Only call `SFSpeechRecognizer.requestAuthorization`
            // when status is actually `.notDetermined`. On iOS 26.4
            // calling it with status already `.authorized` trips a
            // libdispatch queue assertion ("BUG IN CLIENT OF
            // LIBDISPATCH: Assertion failed: Block was %sexpected
            // to execute on queue …") because the completion-based
            // API's internal block dispatches through a queue that
            // Swift 6 strict concurrency assumes is main. Skipping
            // the call when not needed avoids the crash entirely.
            let speechStatus: SFSpeechRecognizerAuthorizationStatus
            if cachedSpeech == .authorized {
                speechStatus = .authorized
                voiceLog
                    .info("[Voice/STT] speech authorization skipped — already cached as .authorized")
            } else {
                voiceLog
                    .info(
                        "[Voice/STT] requesting speech recognition authorization (t+\(Self.elapsed(from: t0))ms)"
                    )
                speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<
                    SFSpeechRecognizerAuthorizationStatus,
                    Never
                >) in
                    SFSpeechRecognizer.requestAuthorization { status in
                        continuation.resume(returning: status)
                    }
                }
                voiceLog
                    .info(
                        "[Voice/STT] speech authorization returned: \(String(describing: speechStatus), privacy: .public) (t+\(Self.elapsed(from: t0))ms)"
                    )
            }
            switch speechStatus {
            case .authorized:
                break
            case .denied, .restricted:
                return .speechDenied
            case .notDetermined:
                return .speechDenied
            @unknown default:
                return .speechDenied
            }

            // Same skip-if-already-granted pattern for mic. The
            // iOS 17+ `requestRecordPermission` is async-native so
            // less crash-prone than the speech equivalent, but
            // there's still no reason to call it when the answer
            // is cached.
            let micGranted: Bool
            if cachedMic == .granted {
                micGranted = true
                voiceLog.info("[Voice/STT] microphone permission skipped — already cached as .granted")
            } else {
                voiceLog
                    .info("[Voice/STT] requesting microphone permission (t+\(Self.elapsed(from: t0))ms)")
                micGranted = await AVAudioApplication.requestRecordPermission()
                voiceLog
                    .info(
                        "[Voice/STT] microphone permission granted=\(micGranted) (t+\(Self.elapsed(from: t0))ms)"
                    )
            }
            guard micGranted else {
                return .microphoneDenied
            }

            // Final check the recognizer is actually usable (locale,
            // network reachability for non-on-device locales, etc.).
            guard let recognizer, recognizer.isAvailable else {
                return .speechUnavailable
            }
            return .authorized
        }

        /// Start a fresh listening session. Resets `transcript` /
        /// `inputLevel` and primes the engine.
        ///
        /// **Async on purpose.** The earlier version was synchronous on
        /// `@MainActor`. `AVAudioSession.setActive(true)` and
        /// `AVAudioEngine.start()` are both synchronous and can block
        /// for hundreds of milliseconds — sometimes several seconds on
        /// a cold boot (Bluetooth handshake, audio HAL init, on-device
        /// speech model warmup). Blocking the main actor during that
        /// window meant the voice-mode view couldn't redraw, so the
        /// user saw a dark/frozen screen until the engine either came
        /// up or failed. The heavy work now runs on a detached task,
        /// state updates hop back to the main actor.
        ///
        /// `onSilenceComplete` fires exactly once per session when the
        /// user goes quiet for `silenceWindow` seconds after producing
        /// some transcript. The caller is expected to call
        /// `stopListening()` in response — silence detection is a hint,
        /// not a teardown.
        public func startListening(
            onSilenceComplete: @escaping @MainActor () -> Void = { },
            onNoSpeechTimeout: @escaping @MainActor () -> Void = { }
        ) async throws {
            let t0 = Date()
            voiceLog.info("[Voice/STT] startListening — entered (isListening=\(self.isListening))")
            guard !self.isListening else {
                return
            }
            guard let recognizer, recognizer.isAvailable else {
                voiceLog
                    .error(
                        "[Voice/STT] startListening: recognizer unavailable (nil=\(self.recognizer == nil) isAvailable=\(self.recognizer?.isAvailable ?? false))"
                    )
                throw VoiceRecognizerError.unavailable
            }

            // Reset session state before wiring anything up so an early
            // throw leaves the recognizer in a clean cancelled state.
            self.transcript = ""
            self.inputLevel = 0
            self.silenceStart = nil
            self.silenceFired = false
            self.onSilenceComplete = onSilenceComplete
            self.noSpeechFired = false
            self.onNoSpeechTimeout = onNoSpeechTimeout
            self.listenStartedAt = Date()
            self.startNoSpeechWatchdog()

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // Force on-device when supported — privacy + offline. Falls
            // back to server-side automatically when the device lacks a
            // downloaded model for the locale.
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
                voiceLog.info("[Voice/STT] using on-device recognition")
            } else {
                voiceLog.info("[Voice/STT] using server-side recognition (on-device unsupported for locale)")
            }
            self.recognitionRequest = request

            voiceLog
                .info(
                    "[Voice/STT] startListening → dispatching audio setup to detached task (t+\(Self.elapsed(from: t0))ms)"
                )
            // The blocking audio I/O — session activation + engine
            // start — runs off the main thread. AVAudioEngine is safe
            // to start from a background queue, and the input node's
            // tap installation just registers a callback; the callback
            // itself runs on the audio render thread regardless of
            // where install was called.
            //
            // Box the engine + request in an `@unchecked Sendable`
            // envelope so Swift 6 strict-concurrency lets us send them
            // off the main actor. Both types are documented thread-safe
            // for the operations we perform (`prepare`, `start`,
            // `installTap`, `inputNode.removeTap`, `request.append`),
            // and the actor itself serialises any other access to them.
            struct AudioSetupBox: @unchecked Sendable {
                let engine: AVAudioEngine
                let request: SFSpeechAudioBufferRecognitionRequest
            }
            let setup = AudioSetupBox(engine: self.audioEngine, request: request)
            try await Task.detached(priority: .userInitiated) {
                let bg0 = Date()
                voiceLog.info("[Voice/STT] (bg) entered detached audio-setup task")

                voiceLog.info("[Voice/STT] (bg) calling configureAudioSession (t+\(Self.elapsed(from: bg0))ms)")
                try Self.configureAudioSession()
                voiceLog.info("[Voice/STT] (bg) configureAudioSession done (t+\(Self.elapsed(from: bg0))ms)")

                voiceLog.info("[Voice/STT] (bg) querying inputNode format (t+\(Self.elapsed(from: bg0))ms)")
                let inputNode = setup.engine.inputNode
                let format = inputNode.outputFormat(forBus: 0)
                voiceLog
                    .info(
                        "[Voice/STT] (bg) inputNode format: sampleRate=\(format.sampleRate) channels=\(format.channelCount) (t+\(Self.elapsed(from: bg0))ms)"
                    )

                // Validate the format BEFORE handing it to
                // `installTap`. AVAudioEngine raises an Obj-C
                // exception ("required condition is false: format
                // != nullptr || ...") when sampleRate or
                // channelCount is 0, which kills the app rather
                // than throwing a Swift-catchable error. Format
                // comes back invalid when the audio session is in
                // a contested state — the device has Spotify
                // playing, is on a phone call, paired to a flaky
                // Bluetooth audio device, etc. Throw a clean
                // recoverable error here so the caller can show
                // a "voice mode unavailable" message instead of
                // crash-reporting back to TestFlight.
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    voiceLog
                        .error(
                            "[Voice/STT] (bg) invalid input format (sampleRate=\(format.sampleRate) channels=\(format.channelCount)) — aborting before installTap to avoid AVAudioEngine assertion crash"
                        )
                    throw VoiceRecognizerError.unavailable
                }

                inputNode.removeTap(onBus: 0)
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                    setup.request.append(buffer)
                    let level = Self.rmsLevel(buffer)
                    // Re-capture `self` weakly when hopping into the
                    // MainActor Task. The outer tap closure's `[weak
                    // self]` doesn't carry into the inner Task —
                    // Swift 6 strict concurrency treats each closure
                    // boundary as a fresh concurrent context.
                    Task { @MainActor [weak self] in
                        self?.handleLevel(level)
                    }
                }
                voiceLog.info("[Voice/STT] (bg) tap installed; calling engine.prepare (t+\(Self.elapsed(from: bg0))ms)")

                setup.engine.prepare()
                voiceLog
                    .info("[Voice/STT] (bg) engine.prepare done; calling engine.start (t+\(Self.elapsed(from: bg0))ms)")

                try setup.engine.start()
                voiceLog
                    .info(
                        "[Voice/STT] (bg) engine.start RETURNED — running=\(setup.engine.isRunning) (t+\(Self.elapsed(from: bg0))ms)"
                    )
            }.value
            voiceLog.info("[Voice/STT] startListening ← detached audio setup complete (t+\(Self.elapsed(from: t0))ms)")

            // Recognition task uses the SDK's own callback queue, so
            // installing it after engine start is fine — and we have
            // to do it on the main actor because the closure routes
            // results through `self.transcript`.
            self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    if let result {
                        self?.transcript = result.bestTranscription.formattedString
                    }
                    if let error {
                        // Don't tear down on transient errors — the
                        // controller will call `stopListening()` if it
                        // needs the engine off.
                        voiceLog
                            .debug(
                                "[Voice/STT] recognition error: \(error.localizedDescription, privacy: .public)"
                            )
                    }
                }
            }

            self.isListening = true
            voiceLog.info("[Voice/STT] listening (locale=\(recognizer.locale.identifier, privacy: .public))")
        }

        /// Stop the recognition task and audio engine. Idempotent.
        public func stopListening() {
            guard self.isListening else {
                return
            }
            self.audioEngine.inputNode.removeTap(onBus: 0)
            self.audioEngine.stop()
            self.recognitionRequest?.endAudio()
            self.recognitionTask?.finish()
            self.recognitionRequest = nil
            self.recognitionTask = nil
            self.isListening = false
            self.inputLevel = 0
            self.onSilenceComplete = nil
            self.noSpeechWatchdog?.cancel()
            self.noSpeechWatchdog = nil
            self.onNoSpeechTimeout = nil
            self.listenStartedAt = nil
            voiceLog.info("[Voice/STT] stopped")
        }

        // MARK: Private

        private let recognizer: SFSpeechRecognizer?
        private let audioEngine = AVAudioEngine()
        private let silenceThreshold: Float
        private let silenceWindow: TimeInterval
        /// How long the recognizer will keep the mic open while
        /// hearing nothing at all (no transcript text yet). When this
        /// elapses we fire `onNoSpeechTimeout` so the controller can
        /// flip into the paused state and shut the engine down.
        private let noSpeechTimeout: TimeInterval

        private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
        private var recognitionTask: SFSpeechRecognitionTask?
        private var silenceStart: Date?
        private var silenceFired = false
        private var onSilenceComplete: (@MainActor () -> Void)?
        /// Wall-clock timestamp set when `startListening` was called.
        /// The no-speech watchdog compares against this to decide
        /// when to give up.
        private var listenStartedAt: Date?
        private var noSpeechWatchdog: Task<Void, Never>?
        private var noSpeechFired = false
        private var onNoSpeechTimeout: (@MainActor () -> Void)?

        /// Track audio session activation in a single place — the voice
        /// session needs `.playAndRecord` because TTS also plays through
        /// the same session.
        ///
        /// `nonisolated` so the detached audio-setup task inside
        /// `startListening` can call it without re-hopping back to the
        /// main actor. `AVAudioSession` is documented thread-safe; the
        /// only reason this method was previously implicit-`@MainActor`
        /// was the enclosing class's `@MainActor` annotation.
        private static nonisolated func configureAudioSession() throws {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        }

        /// Milliseconds elapsed since `from`, formatted for log lines.
        private static nonisolated func elapsed(from start: Date) -> Int {
            Int(Date().timeIntervalSince(start) * 1000)
        }

        /// Compute the root-mean-square level of a PCM buffer, normalized
        /// to `0...1`. Mono-mixes if the buffer is stereo by taking
        /// channel 0 only — voice mode is mono input anyway.
        private static nonisolated func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Float {
            guard let channelData = buffer.floatChannelData else {
                return 0
            }
            let channelCount = Int(buffer.format.channelCount)
            let frames = Int(buffer.frameLength)
            guard frames > 0 else {
                return 0
            }
            var sum: Float = 0
            let samples = channelData[0]
            for frame in 0..<frames {
                let sample = samples[frame]
                sum += sample * sample
            }
            // Normalize: typical speech RMS sits around 0.05–0.3 in raw
            // amplitude; multiply by 4 so a normal-volume voice sits
            // comfortably above the silence threshold and the waveform
            // doesn't look anemic. Clamp at 1.
            let mean = sum / Float(frames * channelCount)
            let rms = sqrt(mean)
            return min(1.0, rms * 4.0)
        }

        /// Watchdog: if the recognizer has been open for
        /// `noSpeechTimeout` seconds and the user hasn't produced
        /// any transcript text, fire `onNoSpeechTimeout` so the
        /// controller can give up the mic. Stops the wasted-power
        /// case of an always-open mic with no speech in earshot.
        private func startNoSpeechWatchdog() {
            self.noSpeechWatchdog?.cancel()
            let timeout = self.noSpeechTimeout
            self.noSpeechWatchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, !Task.isCancelled, self.isListening, !self.noSpeechFired else {
                    return
                }
                // Already heard something? Don't kick the user out
                // mid-thought — the silence-window watchdog handles
                // the "they finished speaking" case separately.
                if !self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return
                }
                self.noSpeechFired = true
                voiceLog
                    .info(
                        "[Voice/STT] no speech for \(Int(timeout))s — firing onNoSpeechTimeout"
                    )
                self.onNoSpeechTimeout?()
            }
        }

        /// Mirror the latest audio level + check silence. Silence is
        /// recognized only after the user has spoken (transcript
        /// non-empty); a 1.4s window with low energy means "they're
        /// done."
        private func handleLevel(_ level: Float) {
            self.inputLevel = level
            // No silence detection until the user has produced *some*
            // transcript. Pre-speech silence is just "they haven't
            // started yet" and shouldn't auto-send an empty turn.
            guard !self.transcript.isEmpty, !self.silenceFired else {
                return
            }
            if level < self.silenceThreshold {
                if self.silenceStart == nil {
                    self.silenceStart = Date()
                } else if let start = silenceStart, Date().timeIntervalSince(start) >= self.silenceWindow {
                    self.silenceFired = true
                    self.onSilenceComplete?()
                }
            } else {
                // Re-arm — user is still talking.
                self.silenceStart = nil
            }
        }
    }
#endif
