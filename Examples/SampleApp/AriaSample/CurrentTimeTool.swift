import Aria
import AriaApple
import Foundation
import FoundationModels

// MARK: - CurrentTimeTool

/// A trivial tool the agent can call to fetch the current time.
///
/// Demonstrates the end-to-end agent + tool flow on FoundationModels:
/// 1. The model decides to call `current_time` based on the user prompt.
/// 2. `FoundationModelsProvider`'s `TypedAriaBridgeTool` adapter
///    dispatches to this `Tool.call` implementation — possible because
///    `Input` is `@Generable`, which is what the iOS 26 system model's
///    tool router actually resolves against.
/// 3. The result is fed back into the session and the model
///    incorporates the time into its reply.
struct CurrentTimeTool: GenerableTool {
    @Generable
    struct Input: Codable {
        @Guide(description: "IANA timezone identifier (e.g. \"America/Los_Angeles\")")
        var timezone: String?
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
                ),
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
