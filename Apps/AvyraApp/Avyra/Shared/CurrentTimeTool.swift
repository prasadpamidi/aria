import Aria
import AriaApple
import Foundation
import FoundationModels

// MARK: - CurrentTimeTool

/// A trivial tool the agent can call to fetch the current time.
///
/// `Input` is `@Generable` so the FoundationModels tool router can
/// resolve calls against it; the same struct's `Codable` conformance
/// keeps the tool usable against non-Apple providers too.
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
    the device's current timezone when omitted.
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
        let timeZone = input.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        let iso = formatter.string(from: Date())
        return Output(iso8601: iso, timezone: timeZone.identifier)
    }
}
