#if canImport(FoundationModels) && (os(iOS) || os(macOS) || os(watchOS) || os(tvOS) || os(visionOS))
    import Aria
    @testable import AriaApple
    import FoundationModels
    import XCTest

    @available(iOS 26.0, macOS 26.0, *)
    enum SessionFactoryTestError: Error {
        case expectedRequirementsReached
        case unexpectedRequirements(FoundationModelsSessionRequirements)
        case builderReached
    }

    @available(iOS 26.0, macOS 26.0, *)
    func testSessionFactory(
        expecting expected: FoundationModelsSessionRequirements
    ) -> FoundationModelsSessionFactory {
        FoundationModelsSessionFactory(
            validate: { actual in
                guard actual == expected else {
                    throw SessionFactoryTestError.unexpectedRequirements(actual)
                }
                throw SessionFactoryTestError.expectedRequirementsReached
            },
            build: { _, _, _ in
                throw SessionFactoryTestError.builderReached
            }
        )
    }

    @available(iOS 26.0, macOS 26.0, *)
    func assertExpectedSessionRequirements<Element>(
        in stream: AsyncThrowingStream<Element, any Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            for try await _ in stream { }
            XCTFail("Expected session factory validation to stop the stream", file: file, line: line)
        } catch let error as AgentError {
            guard case let .providerFailed(_, underlying) = error else {
                return XCTFail("Expected providerFailed, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(
                underlying?.typeName,
                "SessionFactoryTestError",
                file: file,
                line: line
            )
            XCTAssertTrue(
                underlying?.message.contains("expectedRequirementsReached") == true,
                "Expected the requested requirements to reach validation, got \(String(describing: underlying))",
                file: file,
                line: line
            )
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    struct SessionFactoryTestTool: FoundationModels.Tool {
        @Generable
        struct Arguments: Codable {
            var value: String
        }

        typealias Output = String

        let name = "session_factory_test"
        let description = "Exercises session requirements."

        func call(arguments _: Arguments) async throws -> String {
            "ok"
        }
    }
#endif
