#if canImport(MLXLMCommon)
    import XCTest
    @testable import AriaMLX

    final class MLXModelDiskManagerTests: XCTestCase {
        // MARK: Internal

        override func setUpWithError() throws {
            self.tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("aria-mlx-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: self.tempRoot,
                withIntermediateDirectories: true
            )
        }

        override func tearDownWithError() throws {
            try? FileManager.default.removeItem(at: self.tempRoot)
        }

        func testListIsEmptyWhenRootDoesNotExist() throws {
            let manager = MLXModelDiskManager(
                root: self.tempRoot.appendingPathComponent("missing", isDirectory: true)
            )
            XCTAssertEqual(try manager.list(), [])
        }

        func testListEnumeratesOrgAndModelDirs() throws {
            try self.makeFakeModel(org: "mlx-community", name: "ModelA", bytes: 1024)
            try self.makeFakeModel(org: "mlx-community", name: "ModelB", bytes: 2048)
            let manager = MLXModelDiskManager(root: self.tempRoot)
            let entries = try manager.list()
            XCTAssertEqual(
                entries.map(\.id).sorted(),
                ["mlx-community/ModelA", "mlx-community/ModelB"]
            )
        }

        func testReportsDirectorySize() throws {
            try self.makeFakeModel(org: "mlx-community", name: "Sized", bytes: 4096)
            let manager = MLXModelDiskManager(root: self.tempRoot)
            let entries = try manager.list()
            XCTAssertEqual(entries.first?.bytes, 4096)
        }

        func testRemoveDeletesDirectory() throws {
            try self.makeFakeModel(org: "mlx-community", name: "ToDelete", bytes: 256)
            let manager = MLXModelDiskManager(root: self.tempRoot)
            XCTAssertEqual(try manager.list().count, 1)
            try manager.remove(id: "mlx-community/ToDelete")
            XCTAssertEqual(try manager.list().count, 0)
        }

        // MARK: Private

        private var tempRoot: URL = FileManager.default.temporaryDirectory

        // MARK: Helpers

        private func makeFakeModel(org: String, name: String, bytes: Int) throws {
            let modelDir = self.tempRoot
                .appendingPathComponent(org, isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: modelDir,
                withIntermediateDirectories: true
            )
            let weights = modelDir.appendingPathComponent("weights.safetensors")
            try Data(repeating: 0xFF, count: bytes).write(to: weights)
        }
    }
#endif
