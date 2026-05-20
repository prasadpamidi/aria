#if (os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)) && canImport(Speech) && canImport(AVFoundation)
    import Foundation
    import OSLog

    // MARK: - VoiceTurnRequest

    /// One round-trip the voice controller asks the host to run on its
    /// behalf. The closure that implements this gets the user's
    /// transcribed text and returns a `Stream` of cumulative assistant
    /// text — used to drive TTS once the response settles, and to know
    /// when the turn is done.
    public struct VoiceTurnRequest: Sendable {
        // MARK: Lifecycle

        public init(userText: String) {
            self.userText = userText
        }

        // MARK: Public

        /// Stream out the assistant's accumulating reply. Each yield is
        /// the *cumulative* text so far (matches typical streaming-chat
        /// transcripts); the stream finishes when the agent completes
        /// the turn. Throws on stream errors.
        public typealias Stream = AsyncThrowingStream<String, any Error>

        public let userText: String
    }

    // MARK: - VoiceController

    /// State machine that ties together the speech recognizer (input),
    /// the agent (cognition), and the TTS provider (output) into the
    /// always-listening voice-mode loop:
    ///
    ///   listening → user goes quiet → thinking → speaking → listening …
    ///
    /// Owns no UI; views read `state`, `displayLevel`, and
    /// `lastResponseText` to render the current beat.
    ///
    /// **Why the loop is here and not in the view.** Views come and go
    /// when the user closes the screen, but the audio session state,
    /// the recognizer task, and any TTS in flight need explicit cleanup.
    /// Putting the orchestration in an `@Observable` `@MainActor` class
    /// keeps lifecycle handling away from SwiftUI's view-identity rules.
    ///
    /// **Wiring the agent.** Call `bindSender(_:)` once with a closure
    /// that:
    ///   1. Persists the user text into your transcript store (so it
    ///      shows up in chat history when voice mode closes).
    ///   2. Runs the agent.
    ///   3. Yields the assistant's cumulative reply as it streams.
    ///   4. Finishes when the agent emits its terminal event.
    @MainActor
    @Observable
    public final class VoiceController: Identifiable {
        // MARK: Lifecycle

        public init(
            recognizer: SpeechRecognizer,
            tts: any TTSProvider
        ) {
            self.recognizer = recognizer
            self.tts = tts
        }

        // MARK: Public

        public enum State: Equatable, Sendable {
            /// Voice mode not yet started — waiting for permissions or
            /// the first `start()` call.
            case idle
            /// Mic is hot; user speech is being transcribed live.
            case listening
            /// Mic was open and waiting but the user said nothing for
            /// `noSpeechTimeout` seconds, so the recognizer was shut
            /// down to stop wasting battery + audio resources. Views
            /// surface this with a "tap to resume" affordance.
            case paused
            /// Recognizer closed; waiting on the agent's reply.
            case thinking
            /// Reply text is being read out via TTS.
            case speaking
            /// Fatal error for the session.
            case error(String)
        }

        /// Current beat of the loop. Drives the bottom button's enabled
        /// state (only `.listening` enables interaction) and the
        /// waveform tint.
        public private(set) var state: State = .idle

        /// What to render in the waveform RIGHT NOW. Sourced from the
        /// recognizer's mic level while listening and from the TTS
        /// level stream while speaking — the view doesn't need to know
        /// which one is upstream.
        public private(set) var displayLevel: Float = 0

        /// Most recent finalized user transcript. Surface in a developer
        /// panel if you want; the main voice-mode UI is usually text-free.
        public private(set) var lastUserText: String = ""

        /// Most recent assistant text the model emitted (raw, pre-parse).
        /// Useful for a developer panel that exposes what the model
        /// returned, including `<think>` blocks. The text routed to TTS
        /// is the parser's `visible` output, not this — the model should
        /// not narrate its own chain-of-thought.
        public private(set) var lastResponseText: String = ""

        /// Parsed thinking content from the latest assistant turn, when
        /// the active model is a reasoning model and emitted `<think>`
        /// content. Surface in a developer panel only; never spoken.
        public private(set) var lastThinking: String = ""

        /// Names of tools the agent fired this turn (in order).
        public private(set) var lastToolCalls: [String] = []

        /// Soft, transient failure surface for "the turn produced a
        /// reply but it couldn't be delivered as audio" situations:
        /// empty visible response after streaming, or TTS pipeline
        /// failure mid-utterance. These are NOT fatal — the loop
        /// returns to listening on its own — but the user has no
        /// other way to learn the model's reply was lost. Views
        /// surface this as a transient banner; the controller
        /// auto-clears it after `lastErrorDismissAfter` so a long
        /// look-away doesn't leave a stale message visible.
        ///
        /// Distinct from `state == .error(...)` which is the hard,
        /// loop-stopping failure (no mic, no chat sender, no
        /// permissions); soft errors don't tear the loop down.
        public private(set) var lastError: String?

        public nonisolated var id: ObjectIdentifier {
            ObjectIdentifier(self)
        }

        /// Push the latest in-flight per-turn debug info from the chat
        /// side. The chat is the authority — voice mode doesn't re-parse,
        /// it just renders.
        public func updateDevInfo(rawText: String, thinking: String, toolCalls: [String]) {
            self.lastResponseText = rawText
            self.lastThinking = thinking
            self.lastToolCalls = toolCalls
        }

        /// Hand the controller the chat's send pipeline. The closure
        /// must:
        ///   1. Persist the user text into the chat transcript (so it
        ///      shows up in chat history when voice mode closes).
        ///   2. Run the agent.
        ///   3. Yield the assistant's cumulative reply as it streams.
        ///   4. Finish when the agent emits its terminal event.
        public func bindSender(_ sender: @escaping @MainActor (String) -> VoiceTurnRequest.Stream) {
            self.sendUserTurn = sender
        }

        /// Begin the voice-mode loop. Requests permissions if needed; if
        /// denied, transitions to `.error(...)` and stops.
        public func start() async {
            let t0 = Date()
            voiceLog
                .info(
                    "[Voice] VoiceController.start() — entered (state=\(String(describing: self.state), privacy: .public))"
                )
            guard self.sendUserTurn != nil else {
                self.state = .error("Voice mode is not wired up to the chat.")
                return
            }
            voiceLog.info("[Voice] start → requesting permissions (t+\(Self.elapsed(from: t0))ms)")
            let permission = await self.recognizer.requestPermissions()
            voiceLog
                .info(
                    "[Voice] start ← permissions returned: \(String(describing: permission), privacy: .public) (t+\(Self.elapsed(from: t0))ms)"
                )
            guard permission == .authorized else {
                switch permission {
                case .microphoneDenied:
                    self.state = .error("Microphone access is off. Enable it in Settings to use voice mode.")
                case .speechDenied:
                    self.state = .error("Speech recognition is off. Enable it in Settings to use voice mode.")
                case .speechUnavailable:
                    self.state = .error("Speech recognition isn't available right now. Try again later.")
                case .authorized:
                    break
                }
                voiceLog
                    .error(
                        "[Voice] start aborted: permission denied (\(String(describing: permission), privacy: .public))"
                    )
                return
            }
            voiceLog.info("[Voice] start → beginListening (t+\(Self.elapsed(from: t0))ms)")
            self.beginListening()
        }

        /// Tear down the loop. Cancels any in-flight TTS, stops the
        /// recognizer, and resets state. Safe to call repeatedly.
        public func stop() async {
            self.turnTask?.cancel()
            self.turnTask = nil
            self.levelMirrorTask?.cancel()
            self.levelMirrorTask = nil
            self.recognizer.stopListening()
            await self.tts.cancel()
            self.clearLastError()
            self.state = .idle
            self.displayLevel = 0
        }

        /// Manual end-of-turn — called by the bottom button when the
        /// user wants to stop talking without waiting for silence. No-op
        /// if not currently listening.
        public func endTurnNow() {
            guard self.state == .listening else {
                return
            }
            self.submitCurrentTranscript()
        }

        /// Re-open the mic after a no-speech timeout. Called when the
        /// user taps the mic button in the `.paused` state. No-op if
        /// the controller isn't currently paused.
        public func resumeListening() {
            guard self.state == .paused else {
                return
            }
            voiceLog.info("[Voice/Ctrl] resumeListening — user tapped to resume")
            self.beginListening()
        }

        // MARK: Private

        /// How long a soft `lastError` banner stays visible before the
        /// controller auto-clears it. Short enough that a stale message
        /// can't outlive its relevance; long enough that a user
        /// glancing away briefly still catches it. 4 s mirrors iOS
        /// system-banner dwell.
        private static let lastErrorDismissAfter: Duration = .seconds(4)

        private let recognizer: SpeechRecognizer
        private let tts: any TTSProvider

        private var sendUserTurn: (@MainActor (String) -> VoiceTurnRequest.Stream)?
        private var turnTask: Task<Void, Never>?
        private var levelMirrorTask: Task<Void, Never>?
        /// Auto-clears `lastError` after `lastErrorDismissAfter`. Held
        /// here so a new soft error mid-banner cancels the prior
        /// dismiss instead of letting an early timer wipe the fresh
        /// message.
        private var lastErrorClearTask: Task<Void, Never>?

        /// Milliseconds elapsed since `from`, formatted for log lines.
        private static nonisolated func elapsed(from start: Date) -> Int {
            Int(Date().timeIntervalSince(start) * 1000)
        }

        /// Drop `<think>…</think>` blocks and Llama-style template tokens
        /// before handing text to TTS. Matches what host-side message
        /// parsers typically hide in the bubble, so the spoken output
        /// stays aligned with what the user reads.
        private static nonisolated func strippedForSpeech(_ raw: String) -> String {
            var text = raw
            let patterns: [String] = [
                #"<think>[\s\S]*?</think>"#,
                #"</think>"#,
                #"<\|python_tag\|>"#,
                #"<\|eom_id\|>"#,
                #"<\|eot_id\|>"#,
                #"<\|start_header_id\|>[\s\S]*?<\|end_header_id\|>"#,
                #"<\|im_start\|>[\s\S]*?<\|im_end\|>"#,
                #"<\|im_start\|>"#,
                #"<\|im_end\|>"#,
                #"\s*\{\s*"id"\s*:\s*"[A-F0-9-]+"\s*,\s*"stored"\s*:\s*(?:true|false)[^}]*\}\s*"#,
            ]
            for pattern in patterns {
                text = text.replacingOccurrences(
                    of: pattern,
                    with: " ",
                    options: [.regularExpression, .caseInsensitive]
                )
            }
            return text
                .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Recognizer reported `noSpeechTimeout` elapsed without any
        /// transcript text. Shut the mic down and switch to `.paused`
        /// so the user can resume on demand instead of leaving the
        /// engine open burning power forever.
        private func handleNoSpeechTimeout() {
            guard self.state == .listening else {
                return
            }
            voiceLog.notice("[Voice/Ctrl] no-speech timeout fired — switching to .paused")
            self.recognizer.stopListening()
            self.levelMirrorTask?.cancel()
            self.levelMirrorTask = nil
            self.state = .paused
            self.displayLevel = 0
        }

        /// Set the soft-error banner and schedule the auto-clear.
        /// Cancels any in-flight clear task so back-to-back failures
        /// each get their full dwell time.
        private func setLastError(_ message: String) {
            voiceLog.notice("[Voice/Ctrl] soft error surfaced: \(message, privacy: .public)")
            self.lastErrorClearTask?.cancel()
            self.lastError = message
            let dismissAfter = Self.lastErrorDismissAfter
            self.lastErrorClearTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: dismissAfter)
                guard let self, !Task.isCancelled else {
                    return
                }
                self.lastError = nil
                self.lastErrorClearTask = nil
            }
        }

        /// Drop the soft error immediately. Called when a fresh turn
        /// begins so the new context isn't shadowed by a stale banner.
        private func clearLastError() {
            self.lastErrorClearTask?.cancel()
            self.lastErrorClearTask = nil
            self.lastError = nil
        }

        /// Open the recognizer and mirror its mic level into
        /// `displayLevel` so the view's waveform tracks the input.
        ///
        /// `startListening` is async because audio session activation +
        /// `AVAudioEngine.start()` can block for seconds on the first
        /// launch. Awaiting it lets SwiftUI render the "Preparing
        /// voice…" state in between, instead of freezing on a dark
        /// screen until the engine comes up.
        private func beginListening() {
            let t0 = Date()
            voiceLog.info("[Voice] beginListening — entered")
            self.lastResponseText = ""
            Task { @MainActor in
                do {
                    voiceLog
                        .info(
                            "[Voice] beginListening → calling recognizer.startListening (t+\(Self.elapsed(from: t0))ms)"
                        )
                    try await self.recognizer.startListening(
                        onSilenceComplete: { [weak self] in
                            self?.submitCurrentTranscript()
                        },
                        onNoSpeechTimeout: { [weak self] in
                            self?.handleNoSpeechTimeout()
                        }
                    )
                    voiceLog
                        .info(
                            "[Voice] beginListening ← recognizer.startListening returned (t+\(Self.elapsed(from: t0))ms) — switching state to .listening"
                        )
                    self.state = .listening
                    self.mirrorRecognizerLevel()
                } catch {
                    let ns = error as NSError
                    voiceLog
                        .error(
                            "[Voice] startListening THREW after t+\(Self.elapsed(from: t0))ms: \(error.localizedDescription, privacy: .public) [\(ns.domain, privacy: .public) \(ns.code)] userInfo=\(String(describing: ns.userInfo), privacy: .public)"
                        )
                    // Surface the underlying NSError code/domain so a
                    // dead-end like `OSStatus -50` (parameter error
                    // from CoreAudio) doesn't read as a generic
                    // "microphone is broken" to the user.
                    let detail = "\(error.localizedDescription) [\(ns.domain) \(ns.code)]"
                    self.state = .error("Couldn't start the microphone: \(detail)")
                }
            }
        }

        /// Poll `recognizer.inputLevel` at ~30 Hz and copy into our
        /// own `displayLevel`. A poll loop is simpler than subscribing
        /// to `@Observable` changes through KVO-like plumbing, and at
        /// 30 Hz the cost is negligible.
        private func mirrorRecognizerLevel() {
            self.levelMirrorTask?.cancel()
            self.levelMirrorTask = Task { @MainActor [weak self] in
                while !Task.isCancelled, self?.state == .listening {
                    self?.displayLevel = self?.recognizer.inputLevel ?? 0
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        }

        /// User stopped talking (silence-detected OR manual end). Lock
        /// the transcript, transition to `.thinking`, and kick off the
        /// agent turn.
        private func submitCurrentTranscript() {
            let userText = self.recognizer.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !userText.isEmpty else {
                return
            }
            guard let sender = sendUserTurn else {
                self.state = .error("Voice mode is not wired up to the chat.")
                return
            }
            self.recognizer.stopListening()
            self.levelMirrorTask?.cancel()
            self.levelMirrorTask = nil
            self.lastUserText = userText
            self.lastResponseText = ""
            self.lastThinking = ""
            self.lastToolCalls = []
            // A new turn is starting — any soft error from the prior
            // turn is no longer relevant. (The hard `.error` state
            // would already have stopped the loop, so we'd never be
            // here in that case.)
            self.clearLastError()
            // Drop the displayed level to 0 — views typically read
            // `state` directly and switch into a calm processing
            // animation while we're in `.thinking`.
            self.displayLevel = 0
            self.state = .thinking

            let stream = sender(userText)
            self.turnTask = Task { @MainActor [weak self] in
                await self?.consume(stream: stream)
            }
        }

        /// Drain the agent stream into `lastResponseText`, then read
        /// the final response aloud and resume listening.
        private func consume(stream: VoiceTurnRequest.Stream) async {
            var lastText = ""
            do {
                for try await text in stream {
                    if Task.isCancelled {
                        return
                    }
                    lastText = text
                    self.lastResponseText = text
                }
            } catch is CancellationError {
                return
            } catch {
                voiceLog.error("[Voice] agent stream error: \(error.localizedDescription, privacy: .public)")
                self.state = .error("Couldn't get a reply: \(error.localizedDescription)")
                return
            }

            guard !Task.isCancelled else {
                return
            }
            // Defensive last-mile filter for anything the chat parser
            // didn't catch. The chat side is expected to yield clean
            // user-visible text already.
            let spoken = Self.strippedForSpeech(lastText)
            guard !spoken.isEmpty else {
                // Empty reply — either the model produced reasoning
                // only (Qwen 3.x without a final answer), the stream
                // failed silently, or the chat layer filtered
                // everything as tool plumbing. Surface it as a soft
                // banner so the user knows their question didn't
                // produce a spoken reply, then resume listening.
                self.setLastError("No reply to read aloud.")
                self.beginListening()
                return
            }

            // STAY in `.thinking` until the TTS provider actually
            // starts emitting audio. Kokoro's first turn includes a
            // 2–4 s cold-load of the 327 MB model + ~1 s synthesis;
            // flipping the UI to `.speaking` the instant we *call*
            // `tts.speak(...)` made the screen claim "Speaking" while
            // the user heard silence.
            voiceLog.info("[Voice/Ctrl] consume → calling tts.speak (text length=\(spoken.count))")
            let levelStream = self.tts.speak(spoken)
            let streamStart = Date()
            do {
                var hasFlippedToSpeaking = false
                var levelCount = 0
                for try await level in levelStream {
                    if Task.isCancelled {
                        voiceLog
                            .notice(
                                "[Voice/Ctrl] consume: Task.isCancelled mid-stream after \(levelCount) levels — returning"
                            )
                        return
                    }
                    if !hasFlippedToSpeaking {
                        voiceLog
                            .info(
                                "[Voice/Ctrl] consume: first level=\(level) → flipping state to .speaking (t+\(Self.elapsed(from: streamStart))ms)"
                            )
                        self.state = .speaking
                        hasFlippedToSpeaking = true
                    }
                    self.displayLevel = level
                    levelCount += 1
                }
                voiceLog
                    .info(
                        "[Voice/Ctrl] consume: tts level stream completed normally — \(levelCount) levels over \(Self.elapsed(from: streamStart))ms"
                    )
            } catch {
                voiceLog
                    .error("[Voice/Ctrl] consume: tts stream threw: \(error.localizedDescription, privacy: .public)")
                // TTS failed mid-utterance (Kokoro chunk synth failure,
                // audio session yanked, etc.). The reply text is still
                // visible in the transcript when voice mode closes —
                // but in the moment the user heard partial-or-no
                // audio and got no signal. Surface a soft banner.
                self.setLastError("Couldn't read the reply aloud.")
            }
            voiceLog
                .info(
                    "[Voice/Ctrl] consume: post-tts, about to call beginListening — Task.isCancelled=\(Task.isCancelled)"
                )

            guard !Task.isCancelled else {
                return
            }
            // TTS done → loop back to listening for the next turn.
            self.beginListening()
        }
    }
#endif
