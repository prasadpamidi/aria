import Aria
import AriaApple
import FoundationModels

@available(iOS 27.0, *)
@Generable
struct ProofToolInput: Codable {
    @Guide(description: "The exact diagnostic request to acknowledge")
    var request: String
}

struct ProofToolOutput: Codable, Equatable, Sendable {
    let marker: String
}

@available(iOS 27.0, *)
struct ProofTool: GenerableTool {
    typealias Input = ProofToolInput
    typealias Output = ProofToolOutput

    static let name = "coreai_aria_proof"
    static let description = "Returns the deterministic Core AI through Aria proof marker."
    static let inputSchema = JSONSchema.object(
        properties: [
            "request": .string(description: "The diagnostic request to acknowledge."),
        ],
        required: ["request"]
    )

    func call(_: ProofToolInput, context _: ToolContext) async throws -> ProofToolOutput {
        ProofToolOutput(marker: "COREAI_ARIA_TOOL_OK")
    }
}
