import Aria
import Foundation

// MARK: - HashEmbedder

/// A deterministic, dependency-free embedder for tests.
///
/// `HashEmbedder` distributes the unicode scalars of the input across
/// a fixed-dimensional vector and L2-normalizes the result. The output
/// is not semantically meaningful — two paraphrases will not embed
/// similarly — but it is deterministic, fast, and stable across runs,
/// which is exactly what unit tests need.
public struct HashEmbedder: Embedder {
    // MARK: Lifecycle

    public init(dimensions: Int = 64) {
        self.dimensions = dimensions
    }

    // MARK: Public

    public let dimensions: Int
    public let maxInputLength = Int.max
    public let modelIdentifier = "test.hash"

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            self.normalized(self.bucketize(text))
        }
    }

    // MARK: Private

    private func bucketize(_ text: String) -> [Float] {
        var vector = Array(repeating: Float(0), count: self.dimensions)
        for (index, scalar) in text.unicodeScalars.enumerated() {
            let bucket = (Int(scalar.value) &+ index) % self.dimensions
            vector[bucket] += 1
        }
        return vector
    }

    private func normalized(_ vector: [Float]) -> [Float] {
        let magnitude = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard magnitude > 0 else {
            return vector
        }
        return vector.map { $0 / magnitude }
    }
}
