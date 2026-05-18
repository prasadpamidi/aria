import Aria
import AriaTesting
import Foundation

// MARK: - AriaCLI

/// A small headless demo that exercises Aria's recording + replay
/// loop end-to-end.
///
/// Steps:
/// 1. Build an agent backed by `MockLLMProvider` and a trivial
///    `EchoTool`.
/// 2. Run a tool-using turn while a `SessionRecorder` captures
///    everything.
/// 3. Print the produced `SessionBundle` as pretty JSON.
/// 4. Replay the bundle through `SessionReplayer.mockProvider` +
///    `SessionReplayer.tools` against a fresh agent and print the
///    replayed output.
///
/// No Apple-only dependencies — the CLI compiles + runs on Linux too.
@main
enum AriaCLI {
    // MARK: Internal

    static func main() async {
        print("Aria \(AriaInfo.version) — record + replay demo")
        print("AriaTesting \(AriaTesting.version)")
        print(String(repeating: "─", count: 56))

        do {
            let bundle = try await Self.recordOriginalRun()
            try Self.printBundle(bundle)
            try await Self.replayBundle(bundle)
        } catch {
            FileHandle.standardError.write(Data("Demo failed: \(error)\n".utf8))
            exit(1)
        }
    }

    // MARK: Private

    private static func recordOriginalRun() async throws -> SessionBundle {
        print("\n▸ Recording original run …")
        let recorder = SessionRecorder()
        let middleware = RecordingMiddleware(recorder: recorder)
        middleware.bind(providerSystem: "mock", providerModel: "mock.v1", systemPrompt: nil)
        let provider = MockLLMProvider(scenes: [
            .toolCall(
                id: "c1",
                name: "echo",
                arguments: .object(["text": .string("hello aria")])
            ),
            .text("Sure — the echo tool returned: hello aria"),
        ])
        let agent = Agent(config: AgentConfig(
            provider: provider,
            tools: [AnyTool(EchoTool())],
            threadId: "cli-demo",
            middleware: [middleware]
        ))
        for try await event in agent.stream(.message(.user("call echo with hello aria"))) {
            Self.describe(event: event, prefix: "  ")
        }
        return await recorder.bundle()
    }

    private static func printBundle(_ bundle: SessionBundle) throws {
        print("\n▸ SessionBundle JSON:")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bundle)
        if let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    }

    private static func replayBundle(_ bundle: SessionBundle) async throws {
        print("\n▸ Replaying via SessionReplayer …")
        guard let agentRecord = bundle.agent else {
            Swift.print("  (no agent record to replay)")
            return
        }
        let replayProvider = SessionReplayer.mockProvider(from: agentRecord)
        let replayTools = SessionReplayer.tools(from: agentRecord)
        let replayed = Agent(config: AgentConfig(
            provider: replayProvider,
            tools: replayTools,
            threadId: "cli-demo-replay"
        ))
        for try await event in replayed.stream(.message(.user("call echo with hello aria"))) {
            Self.describe(event: event, prefix: "  ")
        }
    }

    private static func describe(event: AgentEvent, prefix: String) {
        switch event {
        case let .userMessageReceived(message):
            Swift.print("\(prefix)user: \(message.textContent)")
        case let .textDelta(chunk):
            Swift.print("\(prefix)assistant: \(chunk)")
        case let .toolCallRequested(call):
            Swift.print("\(prefix)→ tool \(call.name)(\(call.arguments))")
        case let .toolExecutionEnd(callId, result):
            Swift.print("\(prefix)← tool \(callId): \(result.output)")
        case let .finish(reason):
            Swift.print("\(prefix)finish: \(reason)")
        default:
            break
        }
    }
}

// MARK: - EchoTool

/// Minimal cross-platform tool used by the demo.
struct EchoTool: Tool {
    struct Input: Codable {
        let text: String
    }

    struct Output: Codable {
        let echoed: String
    }

    static let name = "echo"
    static let description = "Echo a string back."

    static var inputSchema: JSONSchema {
        .object(properties: ["text": .string()], required: ["text"])
    }

    func call(_ input: Input, context _: ToolContext) async throws -> Output {
        Output(echoed: input.text)
    }
}
