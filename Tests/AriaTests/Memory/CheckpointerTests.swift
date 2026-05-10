import Foundation
import XCTest
@testable import Aria

final class InMemoryCheckpointerTests: XCTestCase {
    func testPutAndGetById() async throws {
        let checkpointer = InMemoryCheckpointer()
        let cp = Checkpoint(
            id: "cp-1",
            threadId: "t",
            state: Data("state-bytes".utf8)
        )
        try await checkpointer.put(cp, threadId: "t")

        let fetched = try await checkpointer.get(threadId: "t", checkpointId: "cp-1")
        XCTAssertEqual(fetched, cp)
    }

    func testGetWithoutIdReturnsLatest() async throws {
        let checkpointer = InMemoryCheckpointer()
        let earlier = Checkpoint(
            id: "early",
            threadId: "t",
            createdAt: Date(timeIntervalSince1970: 100),
            state: Data()
        )
        let later = Checkpoint(
            id: "late",
            threadId: "t",
            createdAt: Date(timeIntervalSince1970: 200),
            state: Data()
        )
        try await checkpointer.put(earlier, threadId: "t")
        try await checkpointer.put(later, threadId: "t")

        let latest = try await checkpointer.latest(threadId: "t")
        XCTAssertEqual(latest?.id, "late")
    }

    func testListReturnsNewestFirst() async throws {
        let checkpointer = InMemoryCheckpointer()
        let cp1 = Checkpoint(id: "cp1", threadId: "t", createdAt: Date(timeIntervalSince1970: 1), state: Data())
        let cp2 = Checkpoint(id: "cp2", threadId: "t", createdAt: Date(timeIntervalSince1970: 2), state: Data())
        let cp3 = Checkpoint(id: "cp3", threadId: "t", createdAt: Date(timeIntervalSince1970: 3), state: Data())
        try await checkpointer.put(cp1, threadId: "t")
        try await checkpointer.put(cp2, threadId: "t")
        try await checkpointer.put(cp3, threadId: "t")

        let list = try await checkpointer.list(threadId: "t", limit: 2)
        XCTAssertEqual(list.map(\.id), ["cp3", "cp2"])
    }

    func testDeleteThreadClearsItOnly() async throws {
        let checkpointer = InMemoryCheckpointer()
        try await checkpointer.put(Checkpoint(threadId: "a", state: Data()), threadId: "a")
        try await checkpointer.put(Checkpoint(threadId: "b", state: Data()), threadId: "b")
        try await checkpointer.deleteThread("a")

        let aLatest = try await checkpointer.latest(threadId: "a")
        let bLatest = try await checkpointer.latest(threadId: "b")
        XCTAssertNil(aLatest)
        XCTAssertNotNil(bLatest)
    }

    func testCheckpointCodableRoundTrip() throws {
        let cp = Checkpoint(
            id: "cp-1",
            threadId: "t",
            parentId: "cp-0",
            state: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            metadata: ["step": .integer(1)]
        )
        let data = try JSONEncoder().encode(cp)
        let decoded = try JSONDecoder().decode(Checkpoint.self, from: data)
        XCTAssertEqual(decoded, cp)
    }
}
