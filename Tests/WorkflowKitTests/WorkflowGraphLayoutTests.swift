import Foundation
import XCTest
@testable import WorkflowKit

final class WorkflowGraphLayoutTests: XCTestCase {
    func testLinearWorkflowLaysOutAsVerticalChain() {
        let stepA = LLMStep(promptTemplate: "Step A")
        let stepB = TransformStep(jsExpression: "b.text", outputBinding: "out")
        let stepC = OutputStep(fields: ["text": "{{out}}"])
        let workflow = Workflow(
            name: "Linear",
            nodes: [.llm(stepA), .transform(stepB), .output(stepC)]
        )

        let layout = WorkflowGraphLayout.compute(for: workflow)

        XCTAssertEqual(layout.rowCount, 3)
        XCTAssertEqual(layout.columnCount, 1)
        XCTAssertEqual(layout.positions[stepA.id]?.row, 0)
        XCTAssertEqual(layout.positions[stepB.id]?.row, 1)
        XCTAssertEqual(layout.positions[stepC.id]?.row, 2)
        for position in layout.positions.values {
            XCTAssertEqual(position.column, 0)
        }
    }

    func testBranchProducesTwoColumnFanOutAndConvergesToOutput() {
        let trueStep = TransformStep(jsExpression: "1", outputBinding: "t")
        let falseStep = TransformStep(jsExpression: "0", outputBinding: "f")
        let branch = BranchStep(
            condition: "b.flag",
            trueBranch: [trueStep.id],
            falseBranch: [falseStep.id]
        )
        let outputStep = OutputStep(fields: [:])
        let workflow = Workflow(
            name: "Branchy",
            nodes: [
                .branch(branch),
                .transform(trueStep),
                .transform(falseStep),
                .output(outputStep),
            ]
        )

        let layout = WorkflowGraphLayout.compute(for: workflow)

        XCTAssertEqual(layout.positions[branch.id]?.row, 0)
        XCTAssertEqual(layout.positions[trueStep.id]?.row, 1)
        XCTAssertEqual(layout.positions[falseStep.id]?.row, 1)
        XCTAssertEqual(layout.positions[outputStep.id]?.row, 2)
        XCTAssertEqual(layout.columnsPerRow[1], 2)
        // Branch should fan out then join on the output row.
        let edges = Set(layout.edges)
        XCTAssertTrue(edges.contains(.init(from: branch.id, to: trueStep.id)))
        XCTAssertTrue(edges.contains(.init(from: branch.id, to: falseStep.id)))
        XCTAssertTrue(edges.contains(.init(from: trueStep.id, to: outputStep.id)))
        XCTAssertTrue(edges.contains(.init(from: falseStep.id, to: outputStep.id)))
    }

    func testParallelChildrenShareLayerAndFanOutFromParent() {
        let childA = LLMStep(promptTemplate: "A")
        let childB = LLMStep(promptTemplate: "B")
        let parallel = ParallelStep(children: [childA.id, childB.id])
        let workflow = Workflow(
            name: "Parallels",
            nodes: [
                .parallel(parallel),
                .llm(childA),
                .llm(childB),
            ]
        )

        let layout = WorkflowGraphLayout.compute(for: workflow)

        XCTAssertEqual(layout.positions[parallel.id]?.row, 0)
        XCTAssertEqual(layout.positions[childA.id]?.row, 1)
        XCTAssertEqual(layout.positions[childB.id]?.row, 1)
        let edges = Set(layout.edges)
        XCTAssertTrue(edges.contains(.init(from: parallel.id, to: childA.id)))
        XCTAssertTrue(edges.contains(.init(from: parallel.id, to: childB.id)))
    }

    func testExplicitEdgesOverrideImplicitChain() {
        let stepA = LLMStep(promptTemplate: "A")
        let stepB = LLMStep(promptTemplate: "B")
        let stepC = OutputStep(fields: [:])
        let workflow = Workflow(
            name: "Explicit",
            nodes: [.llm(stepA), .llm(stepB), .output(stepC)],
            // Reverse the chain — explicit wins.
            edges: [
                WorkflowEdge(from: stepC.id, to: stepB.id),
                WorkflowEdge(from: stepB.id, to: stepA.id),
            ]
        )

        let layout = WorkflowGraphLayout.compute(for: workflow)

        XCTAssertEqual(layout.positions[stepC.id]?.row, 0)
        XCTAssertEqual(layout.positions[stepB.id]?.row, 1)
        XCTAssertEqual(layout.positions[stepA.id]?.row, 2)
    }

    func testEmptyWorkflowProducesEmptyLayout() {
        let workflow = Workflow(name: "Empty")

        let layout = WorkflowGraphLayout.compute(for: workflow)

        XCTAssertEqual(layout.rowCount, 0)
        XCTAssertEqual(layout.columnCount, 0)
        XCTAssertTrue(layout.positions.isEmpty)
        XCTAssertTrue(layout.edges.isEmpty)
    }
}
