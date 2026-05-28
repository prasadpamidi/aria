import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - LLMStep020FieldsTests

/// Lock-in tests for the 0.2.0 LLMStep additions: `retryPolicy`,
/// `timeout`, `attachmentBindings`, `requiredModalities`. Mostly
/// Codable round-trips since the runner-side behaviour is covered
/// by `LLMStepExecutorIntegrationTests` and `RetryPolicyTests`.
@Suite("LLMStep 0.2.0 fields")
struct LLMStep020FieldsTests {
    @Test("New fields have sensible defaults (backwards compatible)")
    func defaults() {
        let step = LLMStep(promptTemplate: "hi")
        #expect(step.retryPolicy == nil)
        #expect(step.timeout == nil)
        #expect(step.attachmentBindings.isEmpty)
        #expect(step.requiredModalities.isEmpty)
    }

    @Test("Codable round-trip preserves new fields when set")
    func codableRoundTrip() throws {
        let step = LLMStep(
            promptTemplate: "describe {{photo}}",
            outputBinding: "caption",
            attachmentBindings: ["photo"],
            requiredModalities: [.image],
            retryPolicy: RetryPolicy(maxAttempts: 3),
            timeout: .seconds(15)
        )
        let data = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(LLMStep.self, from: data)
        #expect(decoded.attachmentBindings == ["photo"])
        #expect(decoded.requiredModalities == [.image])
        #expect(decoded.retryPolicy == step.retryPolicy)
        #expect(decoded.timeout == .seconds(15))
    }

    @Test("Codable on a default step omits empty/nil new fields (no bloat for legacy workflows)")
    func codableOmitsDefaults() throws {
        let step = LLMStep(promptTemplate: "hi")
        let data = try JSONEncoder().encode(step)
        let string = try #require(String(data: data, encoding: .utf8))
        #expect(!string.contains("attachmentBindings"))
        #expect(!string.contains("requiredModalities"))
        #expect(!string.contains("retryPolicy"))
        #expect(!string.contains("timeout"))
    }

    @Test("Pre-0.2.0 persisted LLMStep (without new fields) decodes cleanly")
    func decodesLegacyShape() throws {
        let legacyJSON = """
        {
            "id": "B9C8DE10-0000-0000-0000-000000000001",
            "promptTemplate": "Hello",
            "outputBinding": "text",
            "modelHint": "any"
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(LLMStep.self, from: data)
        #expect(decoded.promptTemplate == "Hello")
        #expect(decoded.attachmentBindings.isEmpty)
        #expect(decoded.retryPolicy == nil)
    }
}
