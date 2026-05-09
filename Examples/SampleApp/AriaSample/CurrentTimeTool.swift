import Aria
import Foundation

// MARK: - CurrentTimeTool

/// A trivial tool the agent can call to fetch the current time.
///
/// Demonstrates the end-to-end agent + tool flow:
/// 1. The model decides to call `current_time` based on the user prompt.
/// 2. `FoundationModelsProvider`'s `AriaBridgeTool` adapter dispatches
///    to this `Tool.call` implementation.
/// 3. The result is fed back into the model session, and the model
///    incorporates the time into its reply.
struct CurrentTimeTool: Tool {
    struct Input: Codable {
        let timezone: String?
    }

    struct Output: Codable {
        let iso8601: String
        let timezone: String
    }

    static let name = "current_time"
    static let description = """
    Returns the current time in ISO-8601 format. Optionally accepts an \
    IANA timezone identifier (e.g. "America/Los_Angeles"); defaults to \
    UTC when omitted.
    """

    static var inputSchema: JSONSchema {
        .object(
            properties: [
                "timezone": .string(
                    description: "IANA timezone identifier"
                )
            ],
            required: []
        )
    }

    func call(_ input: Input, context _: ToolContext) async throws -> Output {
        let identifier = input.timezone ?? "UTC"
        let timeZone = TimeZone(identifier: identifier) ?? TimeZone(identifier: "UTC") ?? .gmt
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        let iso = formatter.string(from: Date())
        return Output(iso8601: iso, timezone: timeZone.identifier)
    }
}
