import Aria
import Foundation
import WorkflowKit

// MARK: - SkillSelectionOutcome

public struct SkillSelectionOutcome: Sendable {
    // MARK: Lifecycle

    public init(query: String, expectedSkill: String?, advertised: [String], blockTokens: Int) {
        self.query = query
        self.expectedSkill = expectedSkill
        self.advertised = advertised
        self.blockTokens = blockTokens
    }

    // MARK: Public

    public let query: String
    public let expectedSkill: String?
    /// Skills the model was offered for this turn.
    public let advertised: [String]
    /// What the catalogue block cost in the prompt.
    public let blockTokens: Int

    /// The skill that answers this turn was on offer.
    ///
    /// Ranking that hides the needed skill is worse than no ranking,
    /// so this is the constraint any reduction has to respect.
    public var offeredTheRightSkill: Bool {
        guard let expected = self.expectedSkill else {
            return true
        }
        return self.advertised.contains(expected)
    }

    /// Skills on offer that cannot help this turn.
    ///
    /// The metric that matters. Each one is a chance the model spends
    /// a round-trip and a body-sized tool result learning nothing —
    /// a cost that is *not* bounded by the catalogue's token count.
    public var distractorsOffered: Int {
        guard let expected = self.expectedSkill else {
            return self.advertised.count
        }
        return self.advertised.count(where: { $0 != expected })
    }
}

// MARK: - SkillSelectionReport

public struct SkillSelectionReport: Sendable {
    // MARK: Lifecycle

    public init(label: String, outcomes: [SkillSelectionOutcome]) {
        self.label = label
        self.outcomes = outcomes
    }

    // MARK: Public

    public let label: String
    public let outcomes: [SkillSelectionOutcome]

    /// Share of turns where the needed skill was still on offer.
    public var recall: Double {
        self.fraction { $0.offeredTheRightSkill }
    }

    public var averageDistractors: Double {
        guard !self.outcomes.isEmpty else {
            return 0
        }
        return Double(self.outcomes.reduce(0) { $0 + $1.distractorsOffered })
            / Double(self.outcomes.count)
    }

    public var averageBlockTokens: Double {
        guard !self.outcomes.isEmpty else {
            return 0
        }
        return Double(self.outcomes.reduce(0) { $0 + $1.blockTokens })
            / Double(self.outcomes.count)
    }

    public func summary() -> String {
        var lines = [
            "\(self.label): recall \(Int((self.recall * 100).rounded()))% · distractors/turn \(Self.oneDecimal(self.averageDistractors)) · catalogue \(Int(self.averageBlockTokens.rounded())) tok",
        ]
        for outcome in self.outcomes where !outcome.offeredTheRightSkill {
            lines.append("  MISS  \"\(outcome.query)\" — wanted \(outcome.expectedSkill ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Private

    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func fraction(_ predicate: (SkillSelectionOutcome) -> Bool) -> Double {
        guard !self.outcomes.isEmpty else {
            return 0
        }
        return Double(self.outcomes.count(where: predicate)) / Double(self.outcomes.count)
    }
}

// MARK: - SkillSelectionEval

/// Measures what ranking the skill catalogue buys.
///
/// This is the tool-selection argument on a second surface, and it is
/// worth measuring separately because the cost shape differs. An
/// unranked *tool* costs its schema. An unranked *skill* costs the
/// chance the model loads it — a whole round-trip and a body-sized
/// result — so the harm is not bounded by what the catalogue adds to
/// the prompt, and a token count alone understates it.
///
/// Deliberately model-free. It measures what the model is *offered*,
/// which is the part the harness controls and the part that is
/// deterministic. What the model then does with the offer is the
/// task-level question `TaskEval` answers.
@MainActor
public struct SkillSelectionEval {
    // MARK: Lifecycle

    public init(cases: [SkillFixtures.Case], provider: SkillProvider) {
        self.cases = cases
        self.provider = provider
    }

    // MARK: Public

    public let cases: [SkillFixtures.Case]
    public let provider: SkillProvider

    /// Every enabled skill, every turn — the behaviour before ranking.
    public func runUnranked(tokenCounter: any TokenCounter = HeuristicTokenCounter()) -> SkillSelectionReport {
        let block = SkillPromptBuilder.systemPromptBlock(provider: self.provider)
        let names = self.provider.enabledSkills().map(\.name)
        let outcomes = self.cases.map { testCase in
            SkillSelectionOutcome(
                query: testCase.query,
                expectedSkill: testCase.expectedSkill,
                advertised: names,
                blockTokens: tokenCounter.count(text: block)
            )
        }
        return SkillSelectionReport(label: "unranked catalogue", outcomes: outcomes)
    }

    /// Ranked per turn by the same selector the tool path uses.
    public func runRanked(
        selector: any ToolSelector,
        limit: Int = 8,
        label: String = "ranked catalogue",
        tokenCounter: any TokenCounter = HeuristicTokenCounter()
    ) async -> SkillSelectionReport {
        var outcomes: [SkillSelectionOutcome] = []
        for testCase in self.cases {
            let block = await SkillPromptBuilder.systemPromptBlock(
                provider: self.provider,
                query: testCase.query,
                selector: selector,
                limit: limit
            )
            outcomes.append(SkillSelectionOutcome(
                query: testCase.query,
                expectedSkill: testCase.expectedSkill,
                advertised: Self.advertisedNames(in: block, from: self.provider),
                blockTokens: tokenCounter.count(text: block)
            ))
        }
        return SkillSelectionReport(label: label, outcomes: outcomes)
    }

    // MARK: Private

    /// Read back what the block actually advertises, rather than
    /// trusting the selector's return value — the builder is what the
    /// model sees, and it is the thing under test.
    private static func advertisedNames(in block: String, from provider: SkillProvider) -> [String] {
        provider.enabledSkills()
            .map(\.name)
            .filter { block.contains("- \($0) —") }
    }
}
