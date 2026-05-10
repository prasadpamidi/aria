import Foundation
import Observation

// MARK: - MemoryProbe

/// Holds the memories `RAGMiddleware.onRecall` surfaced for the most
/// recent agent turn. Backed by `@Observable` so SwiftUI re-renders
/// the assistant bubble's "[recalled: …]" badge as soon as the
/// middleware injects new context.
@MainActor
@Observable
final class MemoryProbe {
    var lastRecalled: [String] = []
}
