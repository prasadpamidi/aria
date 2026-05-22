import Foundation
import Testing
@testable import WorkflowKit

// MARK: - WorkflowNodeTests

/// Codable round-trip for every `WorkflowNode` variant. Each test
/// builds a non-default sample so a missing field surfaces as a
/// decode mismatch.
///
/// The variant discriminator (`type` key) is part of the persisted
/// format — a separate test pins the string forms so a future
/// rename has to consider migration.
struct WorkflowNodeTests {
    // MARK: Internal

    @Test
    func llmStepRoundTrip() throws {
        let step = try LLMStep(
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            promptTemplate: "Summarise {{step1.events}}",
            structuredOutputSchema: #"{"type":"object"}"#,
            modelHint: .foundationModels,
            maxTokens: 256
        )
        let node = WorkflowNode.llm(step)
        try self.assertRoundTrip(node)
    }

    @Test
    func capabilityStepRoundTrip() throws {
        let step = try CapabilityStep(
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
            capability: .calendar,
            method: "eventsToday",
            argsTemplate: ["timezone": "{{input.tz}}"],
            outputBinding: "events"
        )
        let node = WorkflowNode.capability(step)
        try self.assertRoundTrip(node)
    }

    @Test
    func transformStepRoundTrip() throws {
        let step = try TransformStep(
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003")),
            jsExpression: "events.slice(0, 3)",
            outputBinding: "topEvents"
        )
        let node = WorkflowNode.transform(step)
        try self.assertRoundTrip(node)
    }

    @Test
    func branchStepRoundTrip() throws {
        let trueId = UUID()
        let falseId = UUID()
        let step = try BranchStep(
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000004")),
            condition: "events.length > 0",
            trueBranch: [trueId],
            falseBranch: [falseId]
        )
        let node = WorkflowNode.branch(step)
        try self.assertRoundTrip(node)
    }

    @Test
    func parallelStepRoundTrip() throws {
        let child1 = UUID()
        let child2 = UUID()
        let step = try ParallelStep(
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000005")),
            children: [child1, child2]
        )
        let node = WorkflowNode.parallel(step)
        try self.assertRoundTrip(node)
    }

    @Test
    func outputStepRoundTrip() throws {
        let step = try OutputStep(
            id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000006")),
            fields: ["spoken_text": "{{step5.headline}}"]
        )
        let node = WorkflowNode.output(step)
        try self.assertRoundTrip(node)
    }

    /// Pins the variant discriminator strings — these are baked
    /// into persisted workflow JSON. Renaming a case requires a
    /// migration; this test forces the conversation.
    @Test
    func variantDiscriminatorsAreStable() throws {
        let pairs: [(WorkflowNode, String)] = [
            (.llm(LLMStep(promptTemplate: "x")), "llm"),
            (.capability(CapabilityStep(capability: .secrets, method: "get", outputBinding: "x")), "capability"),
            (.transform(TransformStep(jsExpression: "x", outputBinding: "x")), "transform"),
            (.branch(BranchStep(condition: "x")), "branch"),
            (.parallel(ParallelStep(children: [])), "parallel"),
            (.output(OutputStep(fields: [:])), "output"),
        ]
        for (node, expectedType) in pairs {
            let data = try JSONEncoder().encode(node)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(json?["type"] as? String == expectedType, "variant discriminator drift for \(expectedType)")
        }
    }

    // MARK: Private

    // MARK: - Helper

    private func assertRoundTrip(_ node: WorkflowNode) throws {
        let encoded = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(WorkflowNode.self, from: encoded)
        #expect(decoded == node)
        #expect(decoded.id == node.id)
    }
}
