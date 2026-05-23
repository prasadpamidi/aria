// `ARIA_VOICE_KOKORO` is defined by the AriaVoiceKokoro target's
// `swiftSettings` when the `VoiceKokoro` package trait is on;
// otherwise the file compiles to nothing.
//
// The TTS implementation relies on `AVAudioSession`, which is
// iOS / visionOS / tvOS / watchOS only — the nested OS guard
// makes the symbols disappear on macOS so the consumer-facing
// `KokoroTTSProvider` type is platform-correct.
#if ARIA_VOICE_KOKORO && (os(iOS) || os(visionOS) || os(tvOS) || os(watchOS))
    import AriaVoice
    import AVFoundation
    import Foundation
    import KokoroSwift
    import MLX
    import MLXUtilsLibrary
    import NaturalLanguage
    import OSLog

    // MARK: - KokoroTTSProvider

    /// `TTSProvider` backed by the on-device Kokoro 82M model.
    ///
    /// Modeled as an `actor` so all the mutable state — the lazily
    /// loaded engine, voice embedding cache, currently-selected voice
    /// and speed, the AVAudioEngine wiring flag — is automatically
    /// serialized by the actor's executor. No NSLocks, no
    /// `@unchecked Sendable` escape hatch, no mixed `@MainActor`
    /// fields scattered through a class.
    ///
    /// Lifecycle:
    ///   - **First speak**: load `voices.npz` (~14MB), instantiate the
    ///     `KokoroTTS` engine (loads ~327MB model weights). Cold path,
    ///     typically 2–4 s on iPhone 13+.
    ///   - **Subsequent speaks**: engine + voices already in memory;
    ///     hot path is ~real-time-or-faster generation.
    ///   - **cancel()**: stops the player node, finishes any open
    ///     stream continuation. Engine + voices stay loaded so the
    ///     next turn doesn't pay the cold cost.
    ///
    /// `speak(_:)` returns an `AsyncThrowingStream` of level samples.
    /// It is `nonisolated` because the `TTSProvider` protocol declares
    /// the method as synchronous; the body constructs the stream
    /// without touching actor state, then hops back into the actor
    /// via a `Task` to do the real work. CPU-bound generation runs in
    /// `Task.detached` so the actor's executor isn't blocked for the
    /// 100s of milliseconds Kokoro takes to synthesize each turn.
    public actor KokoroTTSProvider: TTSProvider {
        // MARK: Lifecycle

        public init(
            modelURL: URL,
            voicesURL: URL,
            voice: KokoroVoice,
            speed: Float = 1.0
        ) {
            self.modelURL = modelURL
            self.voicesURL = voicesURL
            self.voice = voice
            self.speed = speed
        }

        // MARK: Public

        public enum VoiceProviderError: LocalizedError {
            case voicesUnreadable
            case voiceNotFound(String)
            case audioFormat
            case audioBuffer

            // MARK: Public

            public var errorDescription: String? {
                switch self {
                case .voicesUnreadable:
                    "Couldn't read the Kokoro voices file."
                case let .voiceNotFound(name):
                    "The selected voice (\(name)) isn't in the voices file."
                case .audioFormat:
                    "Couldn't build an audio format for the synthesized samples."
                case .audioBuffer:
                    "Couldn't allocate an audio buffer for playback."
                }
            }
        }

        // MARK: TTSProvider

        /// `nonisolated` so callers can invoke without `await` — the
        /// protocol declares the signature synchronous. The body hops
        /// into actor isolation via a `Task`, and the stream's
        /// `onTermination` handler cancels that task when the consumer
        /// drops the stream (matches the contract `cancel()` provides
        /// in the explicit case).
        public nonisolated func speak(_ text: String) -> AsyncThrowingStream<Float, any Error> {
            AsyncThrowingStream { continuation in
                let task = Task { [weak self] in
                    await self?.runSpeak(text: text, continuation: continuation)
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        }

        public func cancel() async {
            voiceLog
                .notice(
                    "[Voice/Kokoro] cancel() called — activeWork=\(self.activeWork != nil) isPlaying=\(self.playerNode.isPlaying)"
                )
            self.activeWork?.cancel()
            self.activeWork = nil
            self.stopPlayback()
            voiceLog.notice("[Voice/Kokoro] cancel() done")
        }

        /// Settings can mutate the voice / speed between turns. Engine
        /// + voice cache are reused — neither setting requires
        /// re-loading weights.
        public func updateVoice(_ voice: KokoroVoice) {
            self.voice = voice
        }

        public func updateSpeed(_ speed: Float) {
            self.speed = speed
        }

        // MARK: Private

        /// Maximum characters per Kokoro generation call. Kokoro's
        /// upstream limit is ~510 phoneme tokens; in English a token
        /// is roughly 0.6 chars on average, so 250 chars is a safe
        /// ceiling that avoids the engine's `.tooManyTokens` throw.
        private static let chunkCharLimit: Int = 250

        private let modelURL: URL
        private let voicesURL: URL
        private var voice: KokoroVoice
        private var speed: Float

        /// Lazily-built engine — first speak() loads it, subsequent
        /// speaks reuse. Actor isolation guarantees the load happens
        /// exactly once even under concurrent speak() callers.
        private var engine: KokoroTTS?
        /// Decoded voice embeddings from `voices.npz`, keyed by
        /// `"<voiceId>.npy"` to match the on-disk layout.
        private var voices: [String: MLXArray]?

        private let playerNode = AVAudioPlayerNode()
        private let audioEngine = AVAudioEngine()
        private var isAudioEngineWired = false

        /// In-flight speak task (parked here so `cancel()` can stop it).
        /// `Task<Void, Never>` because cancellation is the only
        /// "outcome" we need from outside; the inner work surfaces its
        /// own errors via the stream continuation.
        private var activeWork: Task<Void, Never>?

        /// Mirror image of the one-time setup inside `executeSpeak`.
        /// Lives as a `nonisolated` static so it can be called from
        /// both the happy path and the error/cancellation branches
        /// without the actor's executor having to be re-entered.
        private static nonisolated func teardownPlayback(
            playerNode: AVAudioPlayerNode,
            observers: [NSObjectProtocol],
            tapCounter: TapCounter,
            tapStart: Date,
            tapFormat: AVAudioFormat
        ) {
            playerNode.removeTap(onBus: 0)
            let tapDuration = Date().timeIntervalSince(tapStart)
            let stats = tapCounter.snapshot()
            voiceLog
                .info(
                    "[Voice/Kokoro] teardown: tap removed (was installed for \(String(format: "%.2f", tapDuration))s) — buffers=\(stats.bufferCount) totalFrames=\(stats.totalFrames) audioContent=\(String(format: "%.2f", Double(stats.totalFrames) / tapFormat.sampleRate))s firstAudibleAt=\(stats.firstNonZeroTimestamp.map { String(format: "%.2f", $0.timeIntervalSince(tapStart)) + "s" } ?? "never") lastAudibleAt=\(stats.lastNonZeroTimestamp.map { String(format: "%.2f", $0.timeIntervalSince(tapStart)) + "s" } ?? "never")"
                )
            Self.removePlaybackObservers(observers)
        }

        /// Split `text` into one chunk per sentence — `NLTokenizer`
        /// handles abbreviations + quoted speech so the boundaries
        /// land where a human reader would pause. Each sentence
        /// becomes its own Kokoro generation call:
        ///
        ///   - Sentence-natural pauses between chunks (vs a greedy-pack
        ///     approach that could break mid-sentence when stuffing
        ///     chunks up to a char limit).
        ///   - Smaller chunks → faster individual generation →
        ///     pipelining hides each gap behind the previous
        ///     chunk's playback.
        ///   - Cleaner prosody — Kokoro can shape sentence-level
        ///     intonation when each call is exactly one sentence.
        ///
        /// Oversized sentences (rare; usually run-ons that NLTokenizer
        /// couldn't split) fall back to word-level splitting so we
        /// never hand Kokoro something over `chunkCharLimit`.
        private static func chunkText(_ text: String) -> [String] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return []
            }

            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = trimmed
            var chunks: [String] = []
            tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
                let sentence = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if sentence.isEmpty {
                    return true
                }
                if sentence.count > self.chunkCharLimit {
                    chunks.append(contentsOf: Self.splitOnWords(sentence))
                } else {
                    chunks.append(sentence)
                }
                return true
            }
            return chunks
        }

        private static func splitOnWords(_ text: String) -> [String] {
            let words = text.split(separator: " ").map(String.init)
            var chunks: [String] = []
            var current = ""
            for word in words {
                let candidate = current.isEmpty ? word : current + " " + word
                if candidate.count > self.chunkCharLimit, !current.isEmpty {
                    chunks.append(current)
                    current = word
                } else {
                    current = candidate
                }
            }
            if !current.isEmpty {
                chunks.append(current)
            }
            return chunks
        }

        /// CPU-bound TTS generation. Runs on a detached priority-userInitiated
        /// task so the actor's executor remains responsive (e.g. so a
        /// `cancel()` arriving mid-generation can still run after the
        /// detached task completes — the actor isn't pinned waiting).
        ///
        /// `KokoroTTS` and `MLXArray` aren't declared `Sendable` upstream
        /// but their usage here is single-owner per call (the actor
        /// already serializes access). Boxing them in a small
        /// `@unchecked Sendable` envelope is the minimum unsafe surface
        /// we need to bridge the call.
        private static nonisolated func generate(
            engine: KokoroTTS,
            voiceEmbedding: MLXArray,
            language: Language,
            speed: Float,
            text: String
        ) async throws -> [Float] {
            // `KokoroSwift.Language` isn't declared `Sendable` upstream,
            // so it goes in the envelope alongside `engine` + `embedding`.
            // `text` and `speed` are already `Sendable` and capture
            // normally.
            struct Box: @unchecked Sendable {
                let engine: KokoroTTS
                let embedding: MLXArray
                let language: Language
            }
            let box = Box(engine: engine, embedding: voiceEmbedding, language: language)
            return try await Task.detached(priority: .userInitiated) {
                let (audio, _) = try box.engine.generateAudio(
                    voice: box.embedding,
                    language: box.language,
                    text: text,
                    speed: speed
                )
                return audio
            }.value
        }

        /// Milliseconds elapsed since `from`, formatted for log lines.
        private static nonisolated func elapsed(from start: Date) -> Int {
            Int(Date().timeIntervalSince(start) * 1000)
        }

        /// Subscribes to the audio-subsystem notifications most likely
        /// to cause silent playback interruptions during a Kokoro turn:
        /// session interruption (calls, Siri, alarms), route change
        /// (Bluetooth connect/disconnect, headphone unplug), and engine
        /// configuration change (sample-rate flips). Each is logged
        /// with enough detail to correlate against the playback
        /// timeline.
        private static nonisolated func installPlaybackObservers() -> [NSObjectProtocol] {
            let center = NotificationCenter.default
            var tokens: [NSObjectProtocol] = []

            tokens.append(center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: nil
            ) { notification in
                let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let type = typeValue.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                voiceLog
                    .notice(
                        "[Voice/Kokoro] ⚠️ audio session INTERRUPTION: \(String(describing: type), privacy: .public)"
                    )
            })

            tokens.append(center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: nil
            ) { notification in
                let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                let reason = reasonValue.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                let currentOutputs = AVAudioSession.sharedInstance().currentRoute
                    .outputs.map(\.portType.rawValue).joined(separator: ",")
                voiceLog
                    .notice(
                        "[Voice/Kokoro] ⚠️ audio route CHANGE: reason=\(String(describing: reason), privacy: .public) currentOutputs=[\(currentOutputs, privacy: .public)]"
                    )
            })

            tokens.append(center.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: nil,
                queue: nil
            ) { _ in
                voiceLog.notice("[Voice/Kokoro] ⚠️ AVAudioEngine CONFIGURATION CHANGE")
            })

            tokens.append(center.addObserver(
                forName: AVAudioSession.mediaServicesWereLostNotification,
                object: nil,
                queue: nil
            ) { _ in
                voiceLog.error("[Voice/Kokoro] ‼️ media services WERE LOST")
            })

            tokens.append(center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: nil
            ) { _ in
                voiceLog.error("[Voice/Kokoro] ‼️ media services WERE RESET")
            })

            return tokens
        }

        private static nonisolated func removePlaybackObservers(_ tokens: [NSObjectProtocol]) {
            for token in tokens {
                NotificationCenter.default.removeObserver(token)
            }
        }

        /// RMS metering for a PCM buffer rendered through
        /// `AVAudioPlayerNode`. Mirrors the input-side metering in
        /// `SpeechRecognizer.rmsLevel(_:)` — same 4× normalization so
        /// the user-input and TTS-output waveforms display with
        /// comparable amplitudes.
        private static nonisolated func rmsLevel(buffer: AVAudioPCMBuffer) -> Float {
            guard let channelData = buffer.floatChannelData else {
                return 0
            }
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
            let mean = sum / Float(frames)
            return min(1.0, sqrt(mean) * 4.0)
        }

        /// `AVAudioSession` is process-global state. Configuring it
        /// doesn't need actor isolation — any caller writes the same
        /// values. `nonisolated` so the actor body can call it directly
        /// without bouncing through `await`.
        private static nonisolated func configureAudioSession() throws {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        }

        /// Drive one full speak round end-to-end:
        ///   1. Load engine + voice on the actor (fast; mostly cache hit)
        ///   2. Detach the CPU-bound generation so we don't block the
        ///      actor's executor for hundreds of ms
        ///   3. Hop back to actor for playback + level metering
        private func runSpeak(
            text: String,
            continuation: AsyncThrowingStream<Float, any Error>.Continuation
        ) async {
            // Cancel any previous in-flight speak so a rapid succession
            // of turns doesn't pile up audio.
            self.activeWork?.cancel()

            let workTask = Task<Void, Never> { [weak self] in
                await self?.executeSpeak(text: text, continuation: continuation)
            }
            self.activeWork = workTask
            await workTask.value
        }

        private func executeSpeak(
            text: String,
            continuation: AsyncThrowingStream<Float, any Error>.Continuation
        ) async {
            let t0 = Date()
            let chunks = Self.chunkText(text)
            voiceLog
                .info(
                    "[Voice/Kokoro] executeSpeak: text length=\(text.count) chars → \(chunks.count) chunk(s) — preview=\"\(text.prefix(80), privacy: .public)…\""
                )
            guard !chunks.isEmpty else {
                continuation.finish()
                return
            }
            do {
                voiceLog.info("[Voice/Kokoro] executeSpeak: loading engine + voice embedding")
                let engine = try self.loadedEngine()
                let voiceEmbedding = try self.voiceEmbedding(for: self.voice)
                let language = self.voice.language
                let speed = self.speed

                // ─── One-time playback setup ──────────────────────
                // The earlier revision did all of this inside every
                // `play(samples:into:)` call, so a 12-sentence response
                // hit configureAudioSession + tap install + observer
                // install + tap remove + observer remove ✕ 12. That's
                // wasteful and creates audible blips at chunk
                // boundaries because the tap stream resets each time.
                // Now we set up once, run the chunk loop, and tear
                // down once.
                let sampleRate: Double = 24000
                guard let format = AVAudioFormat(
                    standardFormatWithSampleRate: sampleRate,
                    channels: 1
                ) else {
                    throw VoiceProviderError.audioFormat
                }
                try Self.configureAudioSession()
                try self.wireAudioEngineIfNeeded(format: format)

                let session = AVAudioSession.sharedInstance()
                let initialOutputs = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
                voiceLog
                    .info(
                        "[Voice/Kokoro] executeSpeak: session route outputs=[\(initialOutputs, privacy: .public)] category=\(session.category.rawValue, privacy: .public) sampleRate=\(session.sampleRate)"
                    )

                let observers = Self.installPlaybackObservers()
                let tapFormat = self.playerNode.outputFormat(forBus: 0)
                let tapStart = Date()
                let tapCounter = TapCounter()
                self.playerNode.removeTap(onBus: 0)
                self.playerNode.installTap(
                    onBus: 0,
                    bufferSize: 1024,
                    format: tapFormat
                ) { renderedBuffer, _ in
                    let level = Self.rmsLevel(buffer: renderedBuffer)
                    continuation.yield(level)
                    tapCounter.record(
                        frameLength: Int(renderedBuffer.frameLength),
                        level: level
                    )
                }
                voiceLog
                    .info(
                        "[Voice/Kokoro] executeSpeak: tap installed (sampleRate=\(tapFormat.sampleRate) channels=\(tapFormat.channelCount)) (t+\(Self.elapsed(from: t0))ms)"
                    )

                // Pipeline: while chunk N plays, generate chunk N+1
                // in parallel. Each `generateTask` is detached and
                // awaited at the point we need it. The chunk loop
                // calls a slim `play(buffer:)` that just schedules
                // and awaits playback — all session / tap / observer
                // setup is already done above.
                var pendingSamples: Task<[Float], any Error>? = self.makeGenerateTask(
                    index: 0,
                    chunk: chunks[0],
                    engine: engine,
                    voiceEmbedding: voiceEmbedding,
                    language: language,
                    speed: speed
                )

                chunkLoop: for index in chunks.indices {
                    if Task.isCancelled {
                        voiceLog.notice("[Voice/Kokoro] executeSpeak: cancelled at chunk \(index + 1)/\(chunks.count)")
                        pendingSamples?.cancel()
                        break chunkLoop
                    }

                    let currentTask = pendingSamples
                    let samplesAwaitStart = Date()
                    let samples: [Float]
                    do {
                        samples = try await (currentTask?.value ?? [])
                    } catch is CancellationError {
                        voiceLog.notice("[Voice/Kokoro] executeSpeak: generation task cancelled at chunk \(index + 1)")
                        break chunkLoop
                    }
                    voiceLog
                        .info(
                            "[Voice/Kokoro] executeSpeak: chunk \(index + 1)/\(chunks.count) samples ready (\(samples.count) samples, awaited \(Self.elapsed(from: samplesAwaitStart))ms)"
                        )

                    // Pre-fetch next chunk while this one plays.
                    if index + 1 < chunks.count {
                        pendingSamples = self.makeGenerateTask(
                            index: index + 1,
                            chunk: chunks[index + 1],
                            engine: engine,
                            voiceEmbedding: voiceEmbedding,
                            language: language,
                            speed: speed
                        )
                    } else {
                        pendingSamples = nil
                    }

                    if Task.isCancelled {
                        voiceLog.notice("[Voice/Kokoro] executeSpeak: cancelled after generating chunk \(index + 1)")
                        pendingSamples?.cancel()
                        break chunkLoop
                    }
                    do {
                        try await self.play(samples: samples, format: format, index: index, total: chunks.count)
                    } catch {
                        voiceLog
                            .error(
                                "[Voice/Kokoro] executeSpeak: play(chunk \(index + 1)) threw — \(error.localizedDescription, privacy: .public)"
                            )
                        pendingSamples?.cancel()
                        Self.teardownPlayback(
                            playerNode: self.playerNode,
                            observers: observers,
                            tapCounter: tapCounter,
                            tapStart: tapStart,
                            tapFormat: tapFormat
                        )
                        continuation.finish(throwing: error)
                        return
                    }
                }

                // ─── One-time playback teardown ───────────────────
                Self.teardownPlayback(
                    playerNode: self.playerNode,
                    observers: observers,
                    tapCounter: tapCounter,
                    tapStart: tapStart,
                    tapFormat: tapFormat
                )
                voiceLog
                    .info(
                        "[Voice/Kokoro] executeSpeak: all chunks done, finishing continuation (t+\(Self.elapsed(from: t0))ms)"
                    )
                continuation.yield(0)
                continuation.finish()
            } catch is CancellationError {
                voiceLog.notice("[Voice/Kokoro] executeSpeak: CancellationError caught — finishing stream")
                continuation.finish()
            } catch {
                voiceLog.error("[Voice/Kokoro] executeSpeak: error — \(error.localizedDescription, privacy: .public)")
                continuation.finish(throwing: error)
            }
        }

        /// Wrap `Self.generate` in a `Task` so the caller can hold
        /// onto the result-in-progress and `await` it later. Used by
        /// `executeSpeak` to pre-fetch the next chunk's samples while
        /// the current chunk plays.
        private func makeGenerateTask(
            index: Int,
            chunk: String,
            engine: KokoroTTS,
            voiceEmbedding: MLXArray,
            language: Language,
            speed: Float
        ) -> Task<[Float], any Error> {
            voiceLog
                .info(
                    "[Voice/Kokoro] makeGenerateTask: kicking off chunk \(index + 1) length=\(chunk.count) chars — \"\(chunk.prefix(60), privacy: .public)…\""
                )
            // None of `engine` / `voiceEmbedding` / `language` are
            // declared `Sendable` upstream. Box them so the `Task`
            // closure can capture them across the actor boundary
            // without Swift 6 strict-concurrency rejecting the send.
            // The actor itself serialises any other access to these
            // values, and `generate` runs them on a detached task that
            // is the sole owner during synthesis.
            struct GenBox: @unchecked Sendable {
                let engine: KokoroTTS
                let embedding: MLXArray
                let language: Language
            }
            let box = GenBox(engine: engine, embedding: voiceEmbedding, language: language)
            return Task {
                let start = Date()
                let samples = try await Self.generate(
                    engine: box.engine,
                    voiceEmbedding: box.embedding,
                    language: box.language,
                    speed: speed,
                    text: chunk
                )
                voiceLog
                    .info(
                        "[Voice/Kokoro] makeGenerateTask: chunk \(index + 1) generated in \(Self.elapsed(from: start))ms — \(samples.count) samples"
                    )
                return samples
            }
        }

        private func loadedEngine() throws -> KokoroTTS {
            if let engine {
                return engine
            }
            let new = KokoroTTS(modelPath: self.modelURL, g2p: .misaki)
            self.engine = new
            return new
        }

        private func voiceEmbedding(for voice: KokoroVoice) throws -> MLXArray {
            if let voices, let array = voices[voice.npzKey] {
                return array
            }
            guard let loaded = NpyzReader.read(fileFromPath: self.voicesURL) else {
                throw VoiceProviderError.voicesUnreadable
            }
            self.voices = loaded
            guard let array = loaded[voice.npzKey] else {
                throw VoiceProviderError.voiceNotFound(voice.rawValue)
            }
            return array
        }

        /// Schedule one chunk's PCM buffer on the player node and
        /// await its actual audible-completion. All audio session +
        /// engine + tap + observer setup is done once at the top of
        /// `executeSpeak`; this method just allocates a buffer for
        /// the sample array and schedules it. Keeping this slim is
        /// the difference between sentence-natural seams and
        /// boundary-glitch seams.
        private func play(
            samples: [Float],
            format: AVAudioFormat,
            index: Int,
            total: Int
        ) async throws {
            guard !samples.isEmpty else {
                voiceLog.notice("[Voice/Kokoro] play[\(index + 1)/\(total)]: empty samples — skipping")
                return
            }
            let expectedSeconds = Double(samples.count) / format.sampleRate

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
            ) else {
                throw VoiceProviderError.audioBuffer
            }
            buffer.frameLength = buffer.frameCapacity
            // swiftlint:disable:next force_unwrapping
            let destination = buffer.floatChannelData![0]
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    destination.update(from: base, count: src.count)
                }
            }

            if !self.playerNode.isPlaying {
                self.playerNode.play()
            }

            voiceLog
                .info(
                    "[Voice/Kokoro] play[\(index + 1)/\(total)]: scheduling \(samples.count) samples (\(String(format: "%.2f", expectedSeconds))s)"
                )
            let scheduledAt = Date()
            let callbackType = await self.playerNode.scheduleBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack
            )
            voiceLog
                .info(
                    "[Voice/Kokoro] play[\(index + 1)/\(total)]: scheduleBuffer returned after \(String(format: "%.2f", Date().timeIntervalSince(scheduledAt)))s (expected \(String(format: "%.2f", expectedSeconds))s) callbackType=\(String(describing: callbackType), privacy: .public) cancelled=\(Task.isCancelled)"
                )
        }

        private func wireAudioEngineIfNeeded(format: AVAudioFormat) throws {
            if !self.isAudioEngineWired {
                self.audioEngine.attach(self.playerNode)
                self.audioEngine.connect(
                    self.playerNode,
                    to: self.audioEngine.mainMixerNode,
                    format: format
                )
                self.isAudioEngineWired = true
            }
            if !self.audioEngine.isRunning {
                try self.audioEngine.start()
            }
        }

        private func stopPlayback() {
            voiceLog
                .notice(
                    "[Voice/Kokoro] stopPlayback: playerNode.isPlaying=\(self.playerNode.isPlaying) engine.isRunning=\(self.audioEngine.isRunning)"
                )
            if self.playerNode.isPlaying {
                self.playerNode.stop()
            }
            if self.audioEngine.isRunning {
                self.audioEngine.stop()
            }
        }
    }

    // MARK: - TapCounter

    /// Per-playback metering counter populated from the audio render
    /// thread via `installTap`. Tracks the number of buffers received,
    /// the total frame count, and the timestamps of the first and last
    /// non-silent buffers so we can compare expected vs actual audio
    /// content duration. Uses a small lock to make the audio-thread
    /// writer and the actor-side reader race-free.
    private final class TapCounter: @unchecked Sendable {
        // MARK: Internal

        struct Snapshot {
            let bufferCount: Int
            let totalFrames: Int
            let firstNonZeroTimestamp: Date?
            let lastNonZeroTimestamp: Date?
        }

        func record(frameLength: Int, level: Float) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.bufferCount += 1
            self.totalFrames += frameLength
            if level > 0.01 {
                let now = Date()
                if self.firstNonZero == nil {
                    self.firstNonZero = now
                }
                self.lastNonZero = now
            }
        }

        func snapshot() -> Snapshot {
            self.lock.lock()
            defer { self.lock.unlock() }
            return Snapshot(
                bufferCount: self.bufferCount,
                totalFrames: self.totalFrames,
                firstNonZeroTimestamp: self.firstNonZero,
                lastNonZeroTimestamp: self.lastNonZero
            )
        }

        // MARK: Private

        private let lock = NSLock()
        private var bufferCount = 0
        private var totalFrames = 0
        private var firstNonZero: Date?
        private var lastNonZero: Date?
    }
#endif
