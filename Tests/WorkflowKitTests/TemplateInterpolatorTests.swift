import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - TemplateInterpolatorTests

struct TemplateInterpolatorTests {
    @Test
    func passesThroughLiteralStrings() {
        let result = TemplateInterpolator.render("hello", bindings: [:])
        #expect(result == "hello")
    }

    @Test
    func substitutesTopLevelBindings() {
        let result = TemplateInterpolator.render(
            "Hello, {{name}}",
            bindings: ["name": .string("Prasad")]
        )
        #expect(result == "Hello, Prasad")
    }

    @Test
    func tolerantOfWhitespaceInsideBraces() {
        let result = TemplateInterpolator.render(
            "Hi {{  name  }}",
            bindings: ["name": .string("Prasad")]
        )
        #expect(result == "Hi Prasad")
    }

    @Test
    func descendsIntoObjects() {
        let result = TemplateInterpolator.render(
            "First event: {{events.0.title}}",
            bindings: [
                "events": .array([
                    .object(["title": .string("Standup")]),
                    .object(["title": .string("Lunch")]),
                ]),
            ]
        )
        #expect(result == "First event: Standup")
    }

    @Test
    func missingBindingsRenderEmpty() {
        let result = TemplateInterpolator.render(
            "Hello {{name}}",
            bindings: [:]
        )
        #expect(result == "Hello ")
    }

    @Test
    func arrayIndexOutOfRangeRendersEmpty() {
        let result = TemplateInterpolator.render(
            "Item: {{items.5}}",
            bindings: ["items": .array([.string("only one")])]
        )
        #expect(result == "Item: ")
    }

    @Test
    func numbersFormatWithoutScientificNotation() {
        let result = TemplateInterpolator.render(
            "Steps: {{steps}}",
            bindings: ["steps": .integer(12345)]
        )
        #expect(result == "Steps: 12345")
    }

    @Test
    func boolsRenderAsLowercase() {
        let result = TemplateInterpolator.render(
            "Available: {{flag}}",
            bindings: ["flag": .bool(true)]
        )
        #expect(result == "Available: true")
    }

    @Test
    func objectsRenderAsCompactJSON() {
        let result = TemplateInterpolator.render(
            "Event: {{event}}",
            bindings: ["event": .object(["title": .string("Standup")])]
        )
        #expect(result == "Event: {\"title\":\"Standup\"}")
    }

    @Test
    func multipleSubstitutionsInOneTemplate() {
        let result = TemplateInterpolator.render(
            "{{greeting}}, {{name}}!",
            bindings: [
                "greeting": .string("Hello"),
                "name": .string("Prasad"),
            ]
        )
        #expect(result == "Hello, Prasad!")
    }

    @Test
    func nullRendersEmpty() {
        let result = TemplateInterpolator.render(
            "Value: {{x}}",
            bindings: ["x": .null]
        )
        #expect(result == "Value: ")
    }

    @Test
    func lookupReturnsRawValueForCapabilityArgs() {
        let value = TemplateInterpolator.lookup(
            path: "events.0.title",
            in: ["events": .array([.object(["title": .string("Standup")])])]
        )
        #expect(value == .string("Standup"))
    }

    @Test
    func lookupReturnsNilForMissingPath() {
        let value = TemplateInterpolator.lookup(
            path: "events.0.missing",
            in: ["events": .array([.object(["title": .string("Standup")])])]
        )
        #expect(value == nil)
    }
}
