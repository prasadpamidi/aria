import Foundation

// MARK: - AgentError

/// A typed error emitted by Aria's agent loop, providers, and tool layer.
///
/// All recoverable errors travel as `AgentError` so callers can pattern-match
/// instead of relying on string comparison or untyped `Error` values.
public enum AgentError: Error, Sendable, Equatable {
    /// The provider failed for a reason the underlying SDK reported. The
    /// optional `underlying` carries the original error if available.
    case providerFailed(String, underlying: ErrorBox? = nil)

    /// The agent received a tool call referencing a name not in its tool set.
    case toolNotFound(String)

    /// A tool's `call` method threw. Carries the tool name and the underlying
    /// error.
    case toolExecutionFailed(toolName: String, underlying: ErrorBox)

    /// The agent loop ran out of steps before reaching a terminal state.
    case maxStepsReached(Int)

    /// The model emitted tool arguments that did not parse against the
    /// declared input schema.
    case invalidToolArguments(toolName: String, reason: String)

    /// The run was cancelled (Task cancelled, deadline exceeded, etc.).
    case cancelled

    /// A timeout fired while waiting for an operation.
    case timeout(Duration)

    /// A `ProviderEvent` the agent could not interpret.
    case malformedProviderEvent(String)

    /// Configuration validation failed at run time.
    case configurationInvalid(String)
}

// MARK: - ErrorBox

/// A `Sendable` wrapper around an arbitrary `Error`.
///
/// Swift errors are not inherently `Sendable`. `ErrorBox` captures the
/// localized description and the type name at the point of the throw so
/// the original error can travel across concurrency boundaries inside an
/// `AgentError` value.
public struct ErrorBox: Sendable, Equatable, CustomStringConvertible {
    // MARK: Lifecycle

    public init(_ error: any Error) {
        self.typeName = String(describing: type(of: error))
        self.message = String(describing: error)
    }

    public init(typeName: String, message: String) {
        self.typeName = typeName
        self.message = message
    }

    // MARK: Public

    public let typeName: String
    public let message: String

    public var description: String {
        "\(self.typeName): \(self.message)"
    }
}
