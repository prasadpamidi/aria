import Aria
import AriaApple
import SwiftUI

#if canImport(FoundationModels)
    import FoundationModels
#endif

// MARK: - HaikuChainScreen

/// Standalone demo of the `StateGraph` haiku chain. Two affordances:
///
///  - **Run** — start fresh, stream node-by-node into the state
///    panel, recording a checkpoint after each node via the GRDB
///    checkpointer.
///  - **Resume** — continue from the latest checkpoint stored under
///    `HaikuChain.threadId`. Kill the app mid-run and tap Resume on
///    relaunch to verify the V2 resume API picks up where execution
///    left off.
@available(iOS 26.0, macOS 26.0, *)
struct HaikuChainScreen: View {
    // MARK: Lifecycle

    init(storage: GRDBStorage, sessionRecorder: SessionRecorder) {
        self.storage = storage
        self.sessionRecorder = sessionRecorder
    }

    // MARK: Internal

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                Text(self.rendered)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.tertiarySystemBackground))
                    )
                    .padding()
            }
            HStack(spacing: 12) {
                Button {
                    Task { await self.run() }
                } label: {
                    Label(
                        self.isRunning ? "Running…" : "Run",
                        systemImage: self.isRunning ? "hourglass" : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(self.isRunning)

                Button {
                    Task { await self.resume() }
                } label: {
                    Label("Resume", systemImage: "arrow.uturn.forward")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .disabled(self.isRunning)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .navigationTitle("Haiku chain")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Private

    @State private var rendered: String = "Tap “Run” to stream the graph node by node. Kill mid-run and tap Resume to pick up where it left off."
    @State private var isRunning = false

    private let storage: GRDBStorage
    private let sessionRecorder: SessionRecorder

    @MainActor
    private func run() async {
        let recorder = self.sessionRecorder
        await self.drive { compiled, checkpointConfig in
            compiled.stream(
                initial: HaikuChainState(),
                options: .init(checkpoint: checkpointConfig, recorder: recorder)
            )
        }
    }

    @MainActor
    private func resume() async {
        await self.drive { compiled, _ in
            compiled.resume(
                threadId: HaikuChain.threadId,
                checkpointer: self.storage.checkpointer
            )
        }
    }

    @MainActor
    private func drive(
        _ stream: (
            CompiledStateGraph<HaikuChainState>,
            CompiledStateGraph<HaikuChainState>.CheckpointConfig
        ) -> AsyncThrowingStream<StateGraphEvent<HaikuChainState>, any Error>
    ) async {
        self.isRunning = true
        defer { isRunning = false }
        self.rendered = "[Graph] starting…"
        do {
            let compiled = try HaikuChain.build(agent: HaikuChain.makeAgent())
            let checkpointConfig = CompiledStateGraph<HaikuChainState>.CheckpointConfig(
                checkpointer: self.storage.checkpointer,
                threadId: HaikuChain.threadId
            )
            for try await event in stream(compiled, checkpointConfig) {
                switch event {
                case let .nodeStart(name, state):
                    self.rendered = Self.render(state: state, running: name)
                case let .nodeEnd(_, state):
                    self.rendered = Self.render(state: state, running: nil)
                case let .finish(state):
                    self.rendered = Self.render(state: state, running: nil)
                }
            }
        } catch {
            self.rendered = "[Graph error] \(error)"
        }
    }

    private static func render(state: HaikuChainState, running: String?) -> String {
        var lines = ["[Graph]"]
        if let topic = state.topic {
            lines.append("→ brainstorm: \(topic)")
        }
        if let haiku = state.haiku {
            lines.append("→ haiku:\n\(haiku)")
        }
        if let critique = state.critique {
            lines.append("→ critique: \(critique)")
        }
        if let running {
            lines.append("running \(running)…")
        }
        return lines.joined(separator: "\n")
    }
}
