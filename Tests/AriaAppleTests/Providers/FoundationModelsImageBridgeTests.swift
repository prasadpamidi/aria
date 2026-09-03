#if canImport(FoundationModels) && compiler(>=6.4) && (os(iOS) || os(macOS) || os(watchOS) || os(visionOS))
    import Aria
    @testable import AriaApple
    import CoreGraphics
    import Foundation
    import FoundationModels
    import ImageIO
    import UniformTypeIdentifiers
    import XCTest

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    final class FoundationModelsImageBridgeTests: XCTestCase {
        override func setUpWithError() throws {
            guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *) else {
                throw XCTSkip("Requires iOS 27 / macOS 27 runtime")
            }
        }

        func testJPEGAndPNGDataResolveAsImages() throws {
            let parts = try FoundationModelsImageBridge.resolve(
                [
                    .image(.init(source: .data(try imageData(type: .jpeg), mimeType: "image/jpeg"))),
                    .image(.init(source: .data(try imageData(type: .png), mimeType: "image/png"))),
                ],
                supportsVision: true
            )

            XCTAssertEqual(parts.map(\.kind), [.image, .image])
        }

        func testMixedContentPreservesTextAndImageOrder() throws {
            let parts = try FoundationModelsImageBridge.resolve(
                [
                    .text("before"),
                    .image(.init(source: .data(try imageData(type: .png), mimeType: "image/png"))),
                    .text("after"),
                ],
                supportsVision: true
            )

            XCTAssertEqual(parts.map(\.kind), [.text, .image, .text])
            XCTAssertEqual(parts.compactMap(\.text), ["before", "after"])
        }

        func testInvalidMIMETypeIsRejected() throws {
            XCTAssertThrowsError(
                try FoundationModelsImageBridge.resolve(
                    [.image(.init(source: .data(try imageData(type: .png), mimeType: "image/gif")))],
                    supportsVision: true
                )
            ) { error in
                assertConfigurationInvalid(error)
            }
        }

        func testDeclaredMIMEMustMatchImageData() throws {
            XCTAssertThrowsError(
                try FoundationModelsImageBridge.resolve(
                    [.image(.init(source: .data(try imageData(type: .jpeg), mimeType: "image/png")))],
                    supportsVision: true
                )
            ) { error in
                assertConfigurationInvalid(error)
            }
        }

        func testURLAndIdentifierRequireHostResolution() throws {
            let sources: [ImageContent.Source] = [
                .url(try XCTUnwrap(URL(string: "https://example.com/meal.jpg"))),
                .identifier("photos-local-identifier"),
            ]

            for source in sources {
                XCTAssertThrowsError(
                    try FoundationModelsImageBridge.resolve(
                        [.image(.init(source: source))],
                        supportsVision: true
                    )
                ) { error in
                    assertConfigurationInvalid(error)
                }
            }
        }

        func testTextOnlyModelRejectsImageWithTypedFailure() throws {
            XCTAssertThrowsError(
                try FoundationModelsImageBridge.resolve(
                    [.image(.init(source: .data(try imageData(type: .png), mimeType: "image/png")))],
                    supportsVision: false
                )
            ) { error in
                guard case let AgentError.providerRejected(failure) = error else {
                    return XCTFail("Expected providerRejected, got \(error)")
                }
                XCTAssertEqual(failure.kind, .unsupportedCapability)
            }
        }

        func testPreparedInputAcceptsAnImageOnlyPromptAndRequiresVision() throws {
            let input = try FoundationModelsProvider.prepareInput(
                messages: [Message(
                    role: .user,
                    content: [.image(.init(source: .data(
                        try imageData(type: .png),
                        mimeType: "image/png"
                    )))]
                )],
                defaultInstructions: nil,
                toolDefinitions: [],
                supportsVision: true
            )

            XCTAssertTrue(input.requiresVision)
            XCTAssertTrue(input.transcript.isEmpty)
        }

        func testHistoricalImageBecomesAnAttachmentSegmentInOrder() throws {
            let input = try FoundationModelsProvider.prepareInput(
                messages: [
                    Message(
                        role: .user,
                        content: [
                            .text("before"),
                            .image(.init(source: .data(
                                try imageData(type: .jpeg),
                                mimeType: "image/jpeg"
                            ))),
                            .text("after"),
                        ]
                    ),
                    .user("continue"),
                ],
                defaultInstructions: nil,
                toolDefinitions: [],
                supportsVision: true
            )

            let entry = try XCTUnwrap(input.transcript.first)
            guard case let .prompt(prompt) = entry else {
                return XCTFail("Expected historical prompt")
            }
            XCTAssertEqual(prompt.segments.count, 3)
            guard case .text = prompt.segments[0],
                  case .attachment = prompt.segments[1],
                  case .text = prompt.segments[2] else {
                return XCTFail("Expected text, image, text transcript ordering")
            }
        }

        private func assertConfigurationInvalid(
            _ error: any Error,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            guard case AgentError.configurationInvalid = error else {
                return XCTFail("Expected configurationInvalid, got \(error)", file: file, line: line)
            }
        }

        private func imageData(type: UTType) throws -> Data {
            let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            let image = try XCTUnwrap(context.makeImage())
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
                data,
                type.identifier as CFString,
                1,
                nil
            ))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return data as Data
        }
    }
#endif
