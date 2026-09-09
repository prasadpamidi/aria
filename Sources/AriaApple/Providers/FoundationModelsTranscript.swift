#if canImport(FoundationModels)
    import Aria
    import Foundation
    import FoundationModels

    // MARK: - Transcript construction helpers

    @available(iOS 26.0, macOS 26.0, *)
    extension FoundationModelsProvider {
        /// Build the `Instructions` entry from default + system messages.
        /// Returns `nil` when there is nothing to instruct *and* no tool
        /// definitions to advertise — the model session can run without
        /// an instructions entry in that case.
        static func makeInstructions(
            history: [Message],
            defaultInstructions: String?,
            toolDefinitions: [Transcript.ToolDefinition]
        ) -> Transcript.Instructions? {
            var parts: [String] = []
            if let defaultInstructions, !defaultInstructions.isEmpty {
                parts.append(defaultInstructions)
            }
            for message in history where message.role == .system {
                let text = message.textContent
                if !text.isEmpty {
                    parts.append(text)
                }
            }
            guard !parts.isEmpty || !toolDefinitions.isEmpty else {
                return nil
            }
            let segments: [Transcript.Segment] = parts.isEmpty
                ? []
                : [.text(.init(content: parts.joined(separator: "\n\n")))]
            return Transcript.Instructions(
                segments: segments,
                toolDefinitions: toolDefinitions
            )
        }

        /// Walk the history once collecting `(toolCallId, toolName)` so
        /// later `tool` messages (which only carry an id) can be
        /// reconstructed as `Transcript.ToolOutput` with the right name.
        static func toolNameMap(in history: [Message]) -> [String: String] {
            var map: [String: String] = [:]
            for message in history where message.role == .assistant {
                for call in message.toolCalls {
                    map[call.id] = call.name
                }
            }
            return map
        }

        static func entries(
            for message: Message,
            toolNames: [String: String]
        ) -> [Transcript.Entry] {
            switch message.role {
            case .user: self.entriesForUser(message)
            case .assistant: self.entriesForAssistant(message)
            case .tool: self.entriesForTool(message, toolNames: toolNames)
            case .system: []
            }
        }

        #if compiler(>=6.4)
            @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
            static func buildMultimodalTranscript(
                history: [Message],
                defaultInstructions: String?,
                toolDefinitions: [Transcript.ToolDefinition],
                supportsVision: Bool
            ) throws -> Transcript {
                if history.contains(where: { message in
                    message.role == .system && self.containsImage(in: message.content)
                }) {
                    throw AgentError.configurationInvalid(
                        "Foundation Models does not accept image attachments in system instructions"
                    )
                }

                var entries: [Transcript.Entry] = []
                if let instructions = self.makeInstructions(
                    history: history,
                    defaultInstructions: defaultInstructions,
                    toolDefinitions: toolDefinitions
                ) {
                    entries.append(.instructions(instructions))
                }

                let toolNames = self.toolNameMap(in: history)
                for message in history where message.role != .system {
                    try entries.append(contentsOf: self.multimodalEntries(
                        for: message,
                        toolNames: toolNames,
                        supportsVision: supportsVision
                    ))
                }
                return Transcript(entries: entries)
            }

            @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
            private static func multimodalEntries(
                for message: Message,
                toolNames: [String: String],
                supportsVision: Bool
            ) throws -> [Transcript.Entry] {
                let parts = try FoundationModelsImageBridge.resolve(
                    message.content,
                    supportsVision: supportsVision
                )
                let segments = FoundationModelsImageBridge.transcriptSegments(from: parts)

                switch message.role {
                case .user:
                    guard !segments.isEmpty else {
                        return []
                    }
                    return [.prompt(.init(segments: segments))]
                case .assistant:
                    var entries: [Transcript.Entry] = []
                    if !segments.isEmpty {
                        entries.append(.response(.init(assetIDs: [], segments: segments)))
                    }
                    let calls = message.toolCalls.compactMap(self.transcriptToolCall(from:))
                    if !calls.isEmpty {
                        entries.append(.toolCalls(.init(calls)))
                    }
                    return entries
                case .tool:
                    let id = message.toolCallId ?? UUID().uuidString
                    return [
                        .toolOutput(.init(
                            id: id,
                            toolName: toolNames[id] ?? "unknown",
                            segments: segments
                        )),
                    ]
                case .system:
                    return []
                }
            }
        #endif

        // MARK: - Per-role entry builders

        private static func entriesForUser(_ message: Message) -> [Transcript.Entry] {
            let text = message.textContent
            guard !text.isEmpty else {
                return []
            }
            let prompt = Transcript.Prompt(segments: [.text(.init(content: text))])
            return [.prompt(prompt)]
        }

        private static func entriesForAssistant(_ message: Message) -> [Transcript.Entry] {
            var entries: [Transcript.Entry] = []
            let text = message.textContent
            if !text.isEmpty {
                let response = Transcript.Response(
                    assetIDs: [],
                    segments: [.text(.init(content: text))]
                )
                entries.append(.response(response))
            }
            let calls = message.toolCalls.compactMap(self.transcriptToolCall(from:))
            if !calls.isEmpty {
                entries.append(.toolCalls(.init(calls)))
            }
            return entries
        }

        private static func entriesForTool(
            _ message: Message,
            toolNames: [String: String]
        ) -> [Transcript.Entry] {
            let id = message.toolCallId ?? UUID().uuidString
            let name = toolNames[id] ?? "unknown"
            let output = Transcript.ToolOutput(
                id: id,
                toolName: name,
                segments: [.text(.init(content: message.textContent))]
            )
            return [.toolOutput(output)]
        }

        static func transcriptToolCall(from call: ToolCall) -> Transcript.ToolCall? {
            guard let data = try? call.arguments.canonicalData(),
                  let json = String(bytes: data, encoding: .utf8),
                  let content = try? GeneratedContent(json: json) else {
                return nil
            }
            return Transcript.ToolCall(
                id: call.id,
                toolName: call.name,
                arguments: content
            )
        }
    }

#endif
