#if canImport(FoundationModels)
    import Aria
    import Foundation
    import FoundationModels
    import os

    // MARK: - FoundationModelsToolProbe

    /// Diagnostic probe that pits a hand-coded `FoundationModels.Tool`
    /// (compile-time `@Generable` `Arguments`) against a tool reaching
    /// the same session through `AriaBridgeTool` (runtime
    /// `GeneratedContent` + `DynamicGenerationSchema`). The recorder
    /// flags on the returned `Result` reveal which routing path the
    /// model actually invokes — used to isolate whether observed
    /// "tool never fires" behavior lives in the bridge or in
    /// FoundationModels itself.
    @available(iOS 26.0, macOS 26.0, *)
    public enum FoundationModelsToolProbe {
        // MARK: Public

        public struct ProbeResult: Sendable {
            public let response: String
            public let nativeFired: Bool
            public let bridgeFired: Bool
        }

        /// Run the probe with `prompt`. Returns once the session reply
        /// (and any tool-call cycle) completes.
        public static func run(prompt: String) async throws -> ProbeResult {
            let nativeRecorder = ProbeFireRecorder()
            let bridgeRecorder = ProbeFireRecorder()
            let nativeTool = NativeProbeTool(recorder: nativeRecorder)
            let bridgeAriaTool = AnyTool(BridgeProbeTool(recorder: bridgeRecorder))
            let bridgeTool = try AriaBridgeTool(
                ariaTool: bridgeAriaTool,
                yieldEvent: { _ in }
            )

            let tools: [any FoundationModels.Tool] = [nativeTool, bridgeTool]
            let toolDefinitions = tools.map { Transcript.ToolDefinition(tool: $0) }
            let instructionsText = "You have two tools that return the current time. " +
                "Always invoke one of them when asked about the time."
            let instructions = Transcript.Instructions(
                segments: [.text(.init(content: instructionsText))],
                toolDefinitions: toolDefinitions
            )
            let transcript = Transcript(entries: [.instructions(instructions)])
            let session = LanguageModelSession(tools: tools, transcript: transcript)
            let response = try await session.respond(to: prompt)
            let nativeFired = await nativeRecorder.didFire
            let bridgeFired = await bridgeRecorder.didFire
            return ProbeResult(
                response: String(describing: response.content),
                nativeFired: nativeFired,
                bridgeFired: bridgeFired
            )
        }

        // MARK: Internal

        static let logger = Logger(
            subsystem: "com.aria.AriaApple",
            category: "Probe"
        )
    }

    // MARK: - ProbeFireRecorder

    /// Records whether a probe tool's `call` body ran. Actor isolation
    /// keeps the flag safe across the FoundationModels tool-call
    /// boundary.
    actor ProbeFireRecorder {
        private(set) var didFire = false

        func fire() {
            self.didFire = true
        }
    }

    // MARK: - NativeProbeTool

    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct NativeProbeArgs {
        @Guide(description: "Optional IANA timezone identifier")
        var timezone: String?
    }

    /// Compile-time `@Generable` Arguments path — the WWDC-sample shape.
    @available(iOS 26.0, macOS 26.0, *)
    struct NativeProbeTool: FoundationModels.Tool {
        // MARK: Internal

        typealias Arguments = NativeProbeArgs
        typealias Output = String

        let recorder: ProbeFireRecorder
        let name = "native_probe_time"
        let description = "Returns the current time. NATIVE @Generable variant of the probe."

        func call(arguments: NativeProbeArgs) async throws -> String {
            await self.recorder.fire()
            FoundationModelsToolProbe.logger.debug("PROBE-NATIVE fired")
            return Self.currentTime(in: arguments.timezone)
        }

        // MARK: Private

        private static func currentTime(in tz: String?) -> String {
            let identifier = tz ?? "UTC"
            let timeZone = TimeZone(identifier: identifier) ?? .gmt
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = timeZone
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.string(from: Date())
        }
    }

    // MARK: - BridgeProbeTool

    /// The Aria-side tool the probe wraps in `AriaBridgeTool` so it
    /// reaches the session through the runtime/dynamic-schema path.
    /// Mirrors `NativeProbeTool` so the model has no semantic reason
    /// to prefer one over the other beyond routing mechanics.
    @available(iOS 26.0, macOS 26.0, *)
    struct BridgeProbeTool: Aria.Tool {
        struct Input: Codable {
            let timezone: String?
        }

        struct Output: Codable {
            let iso8601: String
        }

        static let name = "bridge_probe_time"
        static let description =
            "Returns the current time. BRIDGE/DynamicGenerationSchema variant of the probe."

        static var inputSchema: JSONSchema {
            .object(
                properties: [
                    "timezone": .string(description: "IANA timezone identifier"),
                ],
                required: []
            )
        }

        let recorder: ProbeFireRecorder

        func call(_ input: Input, context _: ToolContext) async throws -> Output {
            await self.recorder.fire()
            FoundationModelsToolProbe.logger.debug("PROBE-BRIDGE fired")
            let identifier = input.timezone ?? "UTC"
            let timeZone = TimeZone(identifier: identifier) ?? .gmt
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = timeZone
            formatter.formatOptions = [.withInternetDateTime]
            return Output(iso8601: formatter.string(from: Date()))
        }
    }

#endif
