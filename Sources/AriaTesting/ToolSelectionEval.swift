import Aria
import Foundation

// MARK: - ToolSelectionCase

/// One query with a known-correct outcome.
///
/// Every threshold in tool selection has so far been a guess corrected
/// after a field failure — a cap, a share ceiling, a stopword list that
/// grew twice for the same root cause. A guess is only unavoidable while
/// nothing can be measured, and what makes selection measurable is a set
/// of queries whose right answer is known independently of the ranker.
public struct ToolSelectionCase: Sendable {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - query: The user turn, verbatim where it came from the field.
    ///   - expected: Tools that would let the model answer. A case
    ///     passes on *any* of them, since more than one tool can be a
    ///     legitimate route to the same answer.
    ///   - misleading: Tools that must not outrank every expected one.
    ///
    ///     Recorded separately from a plain miss because the failure is
    ///     worse in kind. A model offered nothing relevant says it
    ///     cannot help; a model offered something plausible and wrong
    ///     calls it, and the turn goes somewhere neither the user nor
    ///     the ranker intended.
    ///   - note: Why the case exists — a field failure, or the property
    ///     it guards.
    public init(
        query: String,
        expected: Set<String>,
        misleading: Set<String> = [],
        note: String = ""
    ) {
        self.query = query
        self.expected = expected
        self.misleading = misleading
        self.note = note
    }

    // MARK: Public

    public let query: String
    public let expected: Set<String>
    public let misleading: Set<String>
    public let note: String
}

// MARK: - ToolSelectionOutcome

public struct ToolSelectionOutcome: Sendable {
    public let testCase: ToolSelectionCase
    public let selected: [String]

    /// Position of the first expected tool, or `nil` when none ranked.
    public var rankOfExpected: Int? {
        self.selected.firstIndex { self.testCase.expected.contains($0) }
    }

    /// An expected tool was offered at all — the model *could* answer.
    public var hit: Bool {
        self.rankOfExpected != nil
    }

    public var topOne: Bool {
        self.rankOfExpected == 0
    }

    /// A misleading tool outranked everything expected.
    public var misled: Bool {
        guard let misleadingRank = selected.firstIndex(where: {
            self.testCase.misleading.contains($0)
        }) else {
            return false
        }
        guard let expectedRank = rankOfExpected else {
            return true
        }
        return misleadingRank < expectedRank
    }
}

// MARK: - ToolSelectionReport

public struct ToolSelectionReport: Sendable {
    // MARK: Lifecycle

    public init(label: String, outcomes: [ToolSelectionOutcome]) {
        self.label = label
        self.outcomes = outcomes
    }

    // MARK: Public

    public let label: String
    public let outcomes: [ToolSelectionOutcome]

    /// Fraction of cases where the model was offered something that
    /// could answer. The metric that matters most: a miss here is a
    /// turn the model cannot complete no matter how well it reasons.
    public var hitRate: Double {
        self.fraction { $0.hit }
    }

    public var topOneRate: Double {
        self.fraction { $0.topOne }
    }

    public var misleadRate: Double {
        self.fraction(\.misled)
    }

    /// Mean reciprocal rank over the first expected tool.
    /// Mean number of tools returned per query.
    ///
    /// The metric this suite was missing. Recall and top-1 say whether
    /// the right tool was offered; neither notices that four wrong ones
    /// came with it. A model asked the time was sent `timezone_math`,
    /// `calculator`, `get_weather` and `get_fasting_status` alongside
    /// `current_time` — every extra one is something it can call
    /// instead of answering.
    public var averageSelected: Double {
        guard !self.outcomes.isEmpty else {
            return 0
        }
        let total = self.outcomes.reduce(0) { $0 + $1.selected.count }
        return Double(total) / Double(self.outcomes.count)
    }

    public var meanReciprocalRank: Double {
        guard !self.outcomes.isEmpty else {
            return 0
        }
        let total = self.outcomes.reduce(0.0) { sum, outcome in
            guard let rank = outcome.rankOfExpected else {
                return sum
            }
            return sum + 1.0 / Double(rank + 1)
        }
        return total / Double(self.outcomes.count)
    }

    public var failures: [ToolSelectionOutcome] {
        self.outcomes.filter { !$0.hit || $0.misled }
    }

    /// Human-readable table. Printed by tests so a regression names the
    /// query that broke rather than only moving a number.
    public func summary() -> String {
        var lines = [
            "\(self.label): hit \(Self.percent(self.hitRate)) · top-1 \(Self.percent(self.topOneRate)) · MRR \(String(format: "%.2f", self.meanReciprocalRank)) · misled \(Self.percent(self.misleadRate)) · avg sent \(String(format: "%.1f", self.averageSelected))",
        ]
        for outcome in self.failures {
            let mark = outcome.misled ? "MISLED" : "MISS"
            lines.append("  \(mark)  \"\(outcome.testCase.query)\"")
            lines.append("        wanted: \(outcome.testCase.expected.sorted().joined(separator: " | "))")
            lines.append("        got:    \(outcome.selected.prefix(5).joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Private

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func fraction(_ predicate: (ToolSelectionOutcome) -> Bool) -> Double {
        guard !self.outcomes.isEmpty else {
            return 0
        }
        return Double(self.outcomes.count(where: predicate)) / Double(self.outcomes.count)
    }
}

// MARK: - ToolSelectionEval

/// Runs a corpus of cases against any `ToolSelector`.
///
/// Deliberately shipped in `AriaTesting` rather than kept in Aria's own
/// tests: the interesting corpus is the consumer's. Avyra's thirty
/// enabled tools and Niora's sixty rank differently from anything a
/// framework test can invent, and the ranker that wins on one may lose
/// on the other.
public struct ToolSelectionEval: Sendable {
    // MARK: Lifecycle

    public init(corpus: [ToolDefinition], cases: [ToolSelectionCase]) {
        self.corpus = corpus
        self.cases = cases
    }

    // MARK: Public

    public let corpus: [ToolDefinition]
    public let cases: [ToolSelectionCase]

    public func run(
        _ selector: any ToolSelector,
        label: String,
        limit: Int = 5
    ) async -> ToolSelectionReport {
        var outcomes: [ToolSelectionOutcome] = []
        for testCase in self.cases {
            let selected = await selector.select(
                from: self.corpus,
                query: testCase.query,
                limit: limit
            )
            outcomes.append(
                ToolSelectionOutcome(testCase: testCase, selected: selected.map(\.name))
            )
        }
        return ToolSelectionReport(label: label, outcomes: outcomes)
    }
}
