import Foundation
import XCTest
@testable import Aria

final class InMemoryVectorStoreTests: XCTestCase {
    func testUpsertAndSearchByCosineRanking() async throws {
        let store = InMemoryVectorStore(dimensions: 3)
        try await store.upsert([
            VectorItem(id: "a", vector: [1, 0, 0], content: "alpha"),
            VectorItem(id: "b", vector: [0, 1, 0], content: "beta"),
            VectorItem(id: "c", vector: [0.9, 0.1, 0], content: "almost-alpha"),
        ])

        let matches = try await store.search(query: [1, 0, 0], topK: 2, filter: nil)
        XCTAssertEqual(matches.map(\.id), ["a", "c"])
        XCTAssertEqual(matches.first?.score ?? 0, 1, accuracy: 0.0001)
    }

    func testDimensionMismatchOnUpsertThrows() async {
        let store = InMemoryVectorStore(dimensions: 3)
        do {
            try await store.upsert([
                VectorItem(id: "a", vector: [1, 0], content: "wrong-shape"),
            ])
            XCTFail("Expected configurationInvalid")
        } catch let error as AgentError {
            if case .configurationInvalid = error {
                // expected
            } else {
                XCTFail("Got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFilterEqualsNarrowsResults() async throws {
        let store = InMemoryVectorStore(dimensions: 2)
        try await store.upsert([
            VectorItem(id: "a", vector: [1, 0], content: "alpha", metadata: ["lang": .string("en")]),
            VectorItem(id: "b", vector: [1, 0], content: "alfa", metadata: ["lang": .string("es")]),
        ])

        let filter = VectorFilter.equals(field: "lang", value: .string("es"))
        let matches = try await store.search(query: [1, 0], topK: 5, filter: filter)
        XCTAssertEqual(matches.map(\.id), ["b"])
    }

    func testFilterAndOrComposes() async throws {
        let store = InMemoryVectorStore(dimensions: 1)
        try await store.upsert([
            VectorItem(id: "a", vector: [1], content: "x", metadata: ["lang": .string("en"), "year": .integer(2020)]),
            VectorItem(id: "b", vector: [1], content: "x", metadata: ["lang": .string("en"), "year": .integer(2025)]),
            VectorItem(id: "c", vector: [1], content: "x", metadata: ["lang": .string("es"), "year": .integer(2025)]),
        ])

        let filter = VectorFilter.and([
            .equals(field: "lang", value: .string("en")),
            .equals(field: "year", value: .integer(2025)),
        ])
        let matches = try await store.search(query: [1], topK: 5, filter: filter)
        XCTAssertEqual(matches.map(\.id), ["b"])
    }

    func testDeleteRemovesById() async throws {
        let store = InMemoryVectorStore(dimensions: 1)
        try await store.upsert([
            VectorItem(id: "a", vector: [1], content: "x"),
            VectorItem(id: "b", vector: [1], content: "y"),
        ])
        try await store.delete(ids: ["a"])
        let count = try await store.count(filter: nil)
        XCTAssertEqual(count, 1)
        let matches = try await store.search(query: [1], topK: 5, filter: nil)
        XCTAssertEqual(matches.map(\.id), ["b"])
    }

    func testListAllAndFiltered() async throws {
        let store = InMemoryVectorStore(dimensions: 1)
        try await store.upsert([
            VectorItem(id: "a", vector: [1], content: "alpha", metadata: ["k": .string("x")]),
            VectorItem(id: "b", vector: [1], content: "beta", metadata: ["k": .string("y")]),
        ])

        let all = try await store.list(filter: nil, limit: 10)
        XCTAssertEqual(Set(all.map(\.id)), Set(["a", "b"]))

        let filtered = try await store.list(
            filter: .equals(field: "k", value: .string("x")),
            limit: 10
        )
        XCTAssertEqual(filtered.map(\.id), ["a"])
    }
}
