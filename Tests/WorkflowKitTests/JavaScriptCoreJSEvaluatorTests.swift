#if canImport(JavaScriptCore)
    import Aria
    import Foundation
    import Testing
    @testable import WorkflowKit

    // MARK: - JavaScriptCoreJSEvaluatorTests

    /// Coverage for the real `WorkflowJSEvaluator`. Exercises
    /// both the `evaluate` and `evaluateBool` paths against
    /// representative bindings.
    struct JavaScriptCoreJSEvaluatorTests {
        // MARK: - evaluate

        @Test
        func returnsStringValue() async throws {
            let evaluator = try JavaScriptCoreJSEvaluator()
            let result = try await evaluator.evaluate(
                expression: "'hello, ' + b.name",
                bindings: ["name": .string("Prasad")]
            )
            #expect(result == .string("hello, Prasad"))
        }

        @Test
        func returnsIntegerForWholeNumberResults() async throws {
            let evaluator = try JavaScriptCoreJSEvaluator()
            let result = try await evaluator.evaluate(
                expression: "b.events.length",
                bindings: [
                    "events": .array([.object([:]), .object([:]), .object([:])]),
                ]
            )
            #expect(result == .integer(3))
        }

        @Test
        func returnsDoubleForFractionalResults() async throws {
            let evaluator = try JavaScriptCoreJSEvaluator()
            let result = try await evaluator.evaluate(
                expression: "1.5 + 2.25",
                bindings: [:]
            )
            #expect(result == .number(3.75))
        }

        @Test
        func returnsArrayValue() async throws {
            let evaluator = try JavaScriptCoreJSEvaluator()
            let result = try await evaluator.evaluate(
                expression: "b.events.map(function(e) { return e.title; })",
                bindings: [
                    "events": .array([
                        .object(["title": .string("Standup")]),
                        .object(["title": .string("Lunch")]),
                    ]),
                ]
            )
            #expect(result == .array([.string("Standup"), .string("Lunch")]))
        }

        @Test
        func returnsObjectValue() async throws {
            let evaluator = try JavaScriptCoreJSEvaluator()
            let result = try await evaluator.evaluate(
                expression: "({first: b.first, second: b.second})",
                bindings: [
                    "first": .string("a"),
                    "second": .integer(2),
                ]
            )
            guard case let .object(dict) = result else {
                Issue.record("Expected object, got \(result)")
                return
            }
            #expect(dict["first"] == .string("a"))
            #expect(dict["second"] == .integer(2))
        }

        @Test
        func returnsNullForUndefined() async throws {
            let evaluator = try JavaScriptCoreJSEvaluator()
            let result = try await evaluator.evaluate(
                expression: "b.missing",
                bindings: ["other": .string("here")]
            )
            #expect(result == .null)
        }

        @Test
        func throwingExpressionSurfaces() async throws {
            let evaluator = try JavaScriptCoreJSEvaluator()
            await #expect(throws: WorkflowEngineError.self) {
                _ = try await evaluator.evaluate(
                    expression: "(function() { throw new Error('bad'); })()",
                    bindings: [:]
                )
            }
        }

        // MARK: - evaluateBool

        @Test
        func evaluateBoolHandlesTrueAndFalse() async throws {
            let evaluator = try JavaScriptCoreJSEvaluator()
            #expect(try await evaluator.evaluateBool(
                expression: "b.events.length > 0",
                bindings: ["events": .array([.object([:])])]
            ))
            #expect(try await !(evaluator.evaluateBool(
                expression: "b.events.length > 0",
                bindings: ["events": .array([])]
            )))
        }

        @Test
        func evaluateBoolCoercesTruthyValues() async throws {
            // Non-bool truthy values evaluate to true via JS
            // coercion, matching Shortcuts' `if` behavior.
            let evaluator = try JavaScriptCoreJSEvaluator()
            #expect(try await evaluator.evaluateBool(
                expression: "b.name",
                bindings: ["name": .string("present")]
            ))
            #expect(try await !(evaluator.evaluateBool(
                expression: "b.name",
                bindings: ["name": .string("")]
            )))
        }
    }
#endif
