import Foundation
import FoundationModels

// MARK: - ActivitySuggestion

/// Demo @Generable type returned by AriaSample's "Suggest" button.
/// Simple shape with a couple of scalars and a list so the streaming
/// partial parser has something to incrementally fill in.
@Generable
struct ActivitySuggestion {
    @Guide(description: "Short, catchy title for the activity (under 6 words)")
    var title: String

    @Guide(description: "One short sentence describing the activity")
    var summary: String

    @Guide(description: "Three concrete steps to try the activity")
    var steps: [String]
}
