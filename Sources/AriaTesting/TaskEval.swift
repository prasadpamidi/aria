import Aria
import Foundation

// MARK: - TaskCase

/// One turn with a known-correct outcome.
///
/// `ToolSelectionEval` measures whether the right tool was *offered*.
/// This measures whether the turn *worked* — which is the only question
/// a user asks, and the one nothing here previously answered.
///
/// The distinction is not academic. Every number this package could
/// previously report was about ranking, while the field traces that
/// motivated the work were full of turns where the right tool was
/// ranked first, called correctly, and the answer was still wrong: a
/// fasting tool returned `time_remaining: "00:00:00"` and the reply
/// said "you have 16 hours left".
public struct TaskCase: Sendable {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - query: The user turn.
    ///   - tools: The surface offered for this task. Include the
    ///     distractors a real app would — a task evaluated against only
    ///     the tool it needs measures nothing about selection.
    ///   - expectedTool: The tool that should be called, or `nil` when
    ///     the correct behaviour is to answer without one.
    ///   - mustContain: Substrings the answer must carry, drawn from
    ///     what the tool actually returns. This is the grounding check:
    ///     an answer that omits the returned value is not using it.
    ///   - mustNotContain: Substrings that indicate invention — a
    ///     fabricated number, a placeholder, a claim of success the
    ///     tool did not report.
    ///   - note: Why this case exists.
    public init(
        query: String,
        tools: [AnyTool],
        expectedTool: String?,
        mustContain: [String] = [],
        mustNotContain: [String] = [],
        note: String = ""
    ) {
        self.query = query
        self.tools = tools
        self.expectedTool = expectedTool
        self.mustContain = mustContain
        self.mustNotContain = mustNotContain
        self.note = note
    }

    // MARK: Public

    public let query: String
    public let tools: [AnyTool]
    public let expectedTool: String?
    public let mustContain: [String]
    public let mustNotContain: [String]
    public let note: String
}

// MARK: - TaskOutcome

public struct TaskOutcome: Sendable {
    // MARK: Lifecycle

    public init(
        testCase: TaskCase,
        answer: String,
        toolsCalled: [String],
        error: String?
    ) {
        self.testCase = testCase
        self.answer = answer
        self.toolsCalled = toolsCalled
        self.error = error
    }

    // MARK: Public

    public let testCase: TaskCase
    public let answer: String
    public let toolsCalled: [String]
    public let error: String?

    /// The expected tool ran — or correctly, none did.
    public var calledExpectedTool: Bool {
        guard let expected = testCase.expectedTool else {
            return self.toolsCalled.isEmpty
        }
        return self.toolsCalled.contains(expected)
    }

    /// The answer carries what the tool returned.
    ///
    /// Calling a tool and then ignoring its result is a distinct
    /// failure from not calling it, and one that ranking metrics
    /// cannot see at all.
    public var grounded: Bool {
        self.testCase.mustContain.allSatisfy { needle in
            self.answer.localizedCaseInsensitiveContains(needle)
        }
    }

    /// The answer invented something.
    public var fabricated: Bool {
        self.testCase.mustNotContain.contains { needle in
            self.answer.localizedCaseInsensitiveContains(needle)
        }
    }

    public var failed: Bool {
        self.error != nil
    }

    /// The turn worked.
    ///
    /// All four conditions, because each corresponds to a failure seen
    /// in the field and any one of them ruins the turn for the user.
    public var passed: Bool {
        self.calledExpectedTool && self.grounded && !self.fabricated && !self.failed
    }

    /// Why it did not pass, for the report.
    public var diagnosis: String? {
        if self.failed {
            return "errored: \(self.error ?? "")"
        }
        if !self.calledExpectedTool {
            let expected = self.testCase.expectedTool ?? "(no tool)"
            let actual = self.toolsCalled.isEmpty ? "(none)" : self.toolsCalled.joined(separator: ", ")
            return "called \(actual), wanted \(expected)"
        }
        if self.fabricated {
            return "invented content the tool never returned"
        }
        if !self.grounded {
            return "ignored the tool's result"
        }
        return nil
    }
}

// MARK: - TaskEvalReport

public struct TaskEvalReport: Sendable {
    // MARK: Lifecycle

    public init(label: String, outcomes: [TaskOutcome], trials: Int = 1) {
        self.label = label
        self.outcomes = outcomes
        self.trials = trials
    }

    // MARK: Public

    public let label: String
    public let outcomes: [TaskOutcome]
    /// How many times each case was run.
    public let trials: Int

    /// Per-trial success rates, in order.
    ///
    /// The headline rate averages these; the spread between them is
    /// what says whether the average means anything. Two identical
    /// configurations of this eval scored 83% and 67% on consecutive
    /// runs — with six cases, one case *is* 17 points, and a single
    /// run cannot distinguish a real effect from which way the
    /// sampler went.
    public var trialSuccessRates: [Double] {
        stride(from: 0, to: self.outcomes.count, by: self.caseCount).map { start in
            let slice = self.outcomes[start..<min(start + self.caseCount, self.outcomes.count)]
            guard !slice.isEmpty else {
                return 0
            }
            return Double(slice.count(where: \.passed)) / Double(slice.count)
        }
    }

    /// The headline: turns that worked end to end.
    public var successRate: Double {
        self.fraction(\.passed)
    }

    public var toolAccuracy: Double {
        self.fraction(\.calledExpectedTool)
    }

    /// Turns whose answer contained something no tool returned. Worth
    /// its own number: a confident wrong answer is worse for a user
    /// than a turn that fails visibly.
    public var fabricationRate: Double {
        self.fraction(\.fabricated)
    }

    public var errorRate: Double {
        self.fraction(\.failed)
    }

    public func summary() -> String {
        var headline =
            "\(self.label): success \(Self.percent(self.successRate)) · tool \(Self.percent(self.toolAccuracy)) · fabricated \(Self.percent(self.fabricationRate)) · errored \(Self.percent(self.errorRate))"
        if self.trials > 1 {
            let rates = self.trialSuccessRates.map(Self.percent).joined(separator: " ")
            headline += "\n  \(self.trials) trials × \(self.caseCount) cases · per-trial success: \(rates)"
        }
        var lines = [headline]
        for outcome in self.outcomes where !outcome.passed {
            lines.append("  FAIL  \"\(outcome.testCase.query)\" — \(outcome.diagnosis ?? "")")
            if !outcome.answer.isEmpty {
                let flat = outcome.answer.replacingOccurrences(of: "\n", with: " ")
                lines.append("        answer: \(flat.prefix(110))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Private

    /// Distinct cases, recovered from the flattened outcome list.
    private var caseCount: Int {
        max(1, self.outcomes.count / max(1, self.trials))
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func fraction(_ predicate: (TaskOutcome) -> Bool) -> Double {
        guard !self.outcomes.isEmpty else {
            return 0
        }
        return Double(self.outcomes.count(where: predicate)) / Double(self.outcomes.count)
    }
}

// MARK: - TaskEval

/// Runs task cases against any agent configuration.
///
/// The configuration is supplied as a factory rather than an `Agent`,
/// so the *same* cases can be run against different harness setups —
/// a bare provider, an assembler with a selector, a different model —
/// and compared. Without a baseline arm, a success rate says nothing
/// about whether the harness earned its complexity.
public struct TaskEval: Sendable {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - cases: The tasks to run.
    ///   - trials: How many times to run each case.
    ///
    ///     Above one because the model is sampled, not deterministic,
    ///     and a single pass over a small corpus measures the sampler
    ///     as much as the harness. Repeating the whole corpus rather
    ///     than each case in turn keeps the trials independent of any
    ///     per-case warm-up.
    public init(cases: [TaskCase], trials: Int = 1) {
        self.cases = cases
        self.trials = max(1, trials)
    }

    // MARK: Public

    public let cases: [TaskCase]
    public let trials: Int

    /// - Parameter makeAgent: Builds the agent under test for one case.
    ///   Receives the case so it can install that task's tool surface.
    ///   Called fresh for every trial, so no state leaks between them.
    public func run(
        label: String,
        makeAgent: @Sendable (TaskCase) async -> Agent
    ) async -> TaskEvalReport {
        var outcomes: [TaskOutcome] = []
        for _ in 0..<self.trials {
            for testCase in self.cases {
                await outcomes.append(Self.run(testCase, makeAgent: makeAgent))
            }
        }
        return TaskEvalReport(label: label, outcomes: outcomes, trials: self.trials)
    }

    // MARK: Private

    private static func run(
        _ testCase: TaskCase,
        makeAgent: @Sendable (TaskCase) async -> Agent
    ) async -> TaskOutcome {
        let agent = await makeAgent(testCase)
        var answer = ""
        var toolsCalled: [String] = []
        var failure: String?
        do {
            for try await event in agent.stream(.message(.user(testCase.query))) {
                switch event {
                case let .textDelta(delta):
                    answer += delta
                case let .toolCallRequested(call):
                    // Covers both routes. The agent loop emits this for
                    // tools it executes itself, and the
                    // FoundationModels provider emits it for the ones
                    // resolved inside its own session — a harness
                    // watching only one would score half the runs as
                    // "called nothing".
                    toolsCalled.append(call.name)
                case let .error(agentError):
                    failure = String(describing: agentError)
                default:
                    break
                }
            }
        } catch {
            failure = String(describing: error)
        }
        return TaskOutcome(
            testCase: testCase,
            answer: answer.trimmingCharacters(in: .whitespacesAndNewlines),
            toolsCalled: Array(Set(toolsCalled)),
            error: failure
        )
    }
}
