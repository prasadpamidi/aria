import Foundation

// MARK: - ToolArgumentCoercion

/// Reconciles a model's tool arguments with the schema it was given.
///
/// Small models quote their numbers. Asked for a weather summary, a
/// 0.8B model emitted `{"days": "1", "latitude": "56.35"}` — every
/// value a string — and the server rejected the call outright:
/// *"Invalid days: must be a finite number, received string"*. The
/// model had the right tool, the right intent and the right values, and
/// the turn failed on quotation marks.
///
/// The schema says what each field is, so the host can fix that without
/// asking the model to try again. This is the same principle the rest
/// of the context layer runs on: the model decides *what*, the host is
/// responsible for the shape.
///
/// **Only lossless conversions.** `"1"` becomes `1`; `"abc"` stays
/// `"abc"` and the server returns its own error, which is more useful
/// than a coercion that invented a number. Nothing is dropped, nothing
/// is added, and a value that already matches its declared type is
/// untouched.
public enum ToolArgumentCoercion {
    // MARK: Public

    /// Coerce `arguments` to the types `schema` declares.
    public static func coerce(_ arguments: JSONValue, to schema: JSONSchema) -> JSONValue {
        switch schema {
        case let .object(properties, _, _, _):
            guard case let .object(values) = arguments else {
                return arguments
            }
            var out: [String: JSONValue] = [:]
            for (key, value) in values {
                // A field the schema does not describe passes through
                // untouched: guessing at its type would be inventing a
                // contract that does not exist.
                guard let propertySchema = properties[key] else {
                    out[key] = value
                    continue
                }
                out[key] = self.coerce(value, to: propertySchema)
            }
            return .object(out)

        case let .array(items, _):
            guard case let .array(values) = arguments else {
                return arguments
            }
            return .array(values.map { self.coerce($0, to: items) })

        case .integer:
            return self.asInteger(arguments) ?? arguments

        case .number:
            return self.asNumber(arguments) ?? arguments

        case .boolean:
            return self.asBoolean(arguments) ?? arguments

        case .string:
            return self.asString(arguments) ?? arguments

        case let .oneOf(options), let .anyOf(options):
            // Try each branch and keep the first that changes
            // something. A union whose branches disagree is ambiguous,
            // and the original is the safer answer.
            for option in options {
                let coerced = self.coerce(arguments, to: option)
                if coerced != arguments {
                    return coerced
                }
            }
            return arguments

        case .allOf, .null:
            return arguments
        }
    }

    // MARK: Private

    private static func asInteger(_ value: JSONValue) -> JSONValue? {
        switch value {
        case .integer:
            return nil
        case let .string(text):
            return Int64(text.trimmingCharacters(in: .whitespaces)).map { .integer($0) }
        case let .number(double):
            // Only when it is exactly an integer. Silently truncating
            // 1.7 to 1 would change what the model asked for.
            guard double.rounded() == double, double.magnitude < 9.2e18 else {
                return nil
            }
            return .integer(Int64(double))
        default:
            return nil
        }
    }

    private static func asNumber(_ value: JSONValue) -> JSONValue? {
        switch value {
        case .number:
            nil
        case let .string(text):
            Double(text.trimmingCharacters(in: .whitespaces)).map { .number($0) }
        case let .integer(int):
            .number(Double(int))
        default:
            nil
        }
    }

    /// Only the spellings JSON itself uses, plus the two a model
    /// reliably means. "yes"/"no" are deliberately absent: they are a
    /// guess about intent rather than a reading of the value.
    private static func asBoolean(_ value: JSONValue) -> JSONValue? {
        guard case let .string(text) = value else {
            return nil
        }
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: return nil
        }
    }

    /// The mirror case: a model that sends a bare number where the
    /// schema wants a string. Less common, equally cheap to fix.
    private static func asString(_ value: JSONValue) -> JSONValue? {
        switch value {
        case let .integer(int):
            .string(String(int))
        case let .number(double):
            .string(
                double.rounded() == double
                    ? String(Int64(double))
                    : String(double)
            )
        case let .bool(flag):
            .string(flag ? "true" : "false")
        default:
            nil
        }
    }
}
