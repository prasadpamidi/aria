import Aria
import Foundation

// MARK: - TemplateInterpolator

/// Handlebars-style `{{path}}` substitution against a workflow's
/// running bindings. Used to:
///
///   * Build LLM-step prompt strings: `Narrate {{events}} for {{input.user}}`.
///   * Resolve capability-step args: `["city": "{{input.city}}"]`.
///   * Compute the terminal `output` node's field values.
///
/// Path syntax:
///
///   * `{{name}}`              — top-level binding lookup.
///   * `{{name.field}}`        — descend into an object.
///   * `{{name.0.title}}`      — array index access (decimal).
///   * `{{name.field.0.sub}}`  — arbitrary depth.
///
/// **Rendering rules**:
///   * Strings are inserted verbatim (no escaping — the consumer
///     is either the model's prompt or a typed-arg pass-through).
///   * Numbers/booleans use Swift's default `description`.
///   * Objects/arrays serialize to compact JSON (so a prompt that
///     embeds a structured value gets a readable JSON literal,
///     not a Swift-style `[String: Optional]` dump).
///   * `null` and missing paths render as the empty string.
///
/// `nil`-on-missing is deliberate: it's what makes "weather plugin
/// returned no result, so the brief skips weather" workflows
/// degrade gracefully instead of crashing.
public enum TemplateInterpolator {
    // MARK: Public

    /// Interpolate every `{{path}}` in `template` against
    /// `bindings`. Returns the resolved string.
    public static func render(_ template: String, bindings: [String: JSONValue]) -> String {
        guard template.contains("{{") else {
            return template
        }
        var output = ""
        output.reserveCapacity(template.count)
        var cursor = template.startIndex

        while cursor < template.endIndex {
            if let openRange = template.range(of: "{{", range: cursor..<template.endIndex),
               let closeRange = template.range(of: "}}", range: openRange.upperBound..<template.endIndex) {
                output.append(contentsOf: template[cursor..<openRange.lowerBound])
                let path = template[openRange.upperBound..<closeRange.lowerBound]
                    .trimmingCharacters(in: .whitespaces)
                output.append(self.renderValue(self.lookup(path: path, in: bindings)))
                cursor = closeRange.upperBound
            } else {
                output.append(contentsOf: template[cursor..<template.endIndex])
                break
            }
        }
        return output
    }

    /// Resolve a `{{path}}` style expression to the underlying
    /// `JSONValue`. Returns `nil` when any segment is missing —
    /// useful for capability-arg interpolation where the consumer
    /// wants to distinguish "value was null" from "value was the
    /// string 'null'".
    public static func lookup(
        path: String,
        in bindings: [String: JSONValue]
    ) -> JSONValue? {
        let segments = path
            .split(separator: ".")
            .map { String($0) }
        guard let head = segments.first,
              var current = bindings[head] else {
            return nil
        }
        for segment in segments.dropFirst() {
            switch current {
            case let .object(dict):
                guard let next = dict[segment] else {
                    return nil
                }
                current = next
            case let .array(items):
                guard let index = Int(segment), index >= 0, index < items.count else {
                    return nil
                }
                current = items[index]
            default:
                return nil
            }
        }
        return current
    }

    // MARK: Private

    /// String representation of a JSONValue for prompt insertion.
    private static func renderValue(_ value: JSONValue?) -> String {
        guard let value, value != .null else {
            return ""
        }
        switch value {
        case let .string(string):
            return string
        case let .bool(flag):
            return flag ? "true" : "false"
        case let .integer(integer):
            return String(integer)
        case let .number(double):
            return String(double)
        case .null:
            return ""
        case .object, .array:
            return Self.compactJSON(value)
        }
    }

    /// Serialize a structured value as compact JSON. Encoder
    /// configuration matches `WorkflowCodec.encode(_:)` for the
    /// .secondsSince1970 strategy + no extra whitespace.
    private static func compactJSON(_ value: JSONValue) -> String {
        do {
            let data = try JSONEncoder().encode(value)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
