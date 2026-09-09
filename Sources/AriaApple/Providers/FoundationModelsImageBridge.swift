#if canImport(FoundationModels) && compiler(>=6.4) && (os(iOS) || os(macOS) || os(watchOS) || os(visionOS))
    import Aria
    import CoreGraphics
    import Foundation
    import FoundationModels
    import ImageIO
    import UniformTypeIdentifiers

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
    enum FoundationModelsImageBridge {
        // MARK: Internal

        enum PartKind: Equatable {
            case text
            case image
        }

        enum ResolvedPart {
            case text(String)
            case image(CGImage)

            // MARK: Internal

            var kind: PartKind {
                switch self {
                case .text: .text
                case .image: .image
                }
            }

            var text: String? {
                guard case let .text(value) = self else {
                    return nil
                }
                return value
            }
        }

        static func resolve(
            _ content: [ContentPart],
            supportsVision: Bool
        ) throws -> [ResolvedPart] {
            try content.compactMap { part in
                switch part {
                case let .text(value):
                    return .text(value)
                case let .image(image):
                    guard supportsVision else {
                        throw AgentError.providerRejected(.init(
                            kind: .unsupportedCapability,
                            message: "The selected Foundation Models model does not support image input"
                        ))
                    }
                    return try .image(self.decode(image))
                case .audio, .toolUse, .toolResult:
                    return nil
                }
            }
        }

        static func prompt(from parts: [ResolvedPart]) -> Prompt {
            let components = parts.map { part in
                switch part {
                case let .text(value):
                    Prompt(value)
                case let .image(image):
                    Prompt(Attachment(image))
                }
            }
            return Prompt(components)
        }

        static func transcriptSegments(from parts: [ResolvedPart]) -> [Transcript.Segment] {
            parts.map { part in
                switch part {
                case let .text(value):
                    .text(.init(content: value))
                case let .image(image):
                    .attachment(.init(content: .image(.init(image))))
                }
            }
        }

        // MARK: Private

        private static func decode(_ image: ImageContent) throws -> CGImage {
            guard case let .data(data, declaredMIMEType) = image.source else {
                throw AgentError.configurationInvalid(
                    "Foundation Models image URLs and identifiers must be resolved to in-memory data by the host"
                )
            }

            let normalizedMIMEType = declaredMIMEType
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let expectedType: UTType
            switch normalizedMIMEType {
            case "image/jpeg", "image/jpg":
                expectedType = .jpeg
            case "image/png":
                expectedType = .png
            default:
                throw AgentError.configurationInvalid(
                    "Foundation Models supports in-memory JPEG and PNG image data; received \(declaredMIMEType)"
                )
            }

            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let detectedIdentifier = CGImageSourceGetType(source),
                  detectedIdentifier as String == expectedType.identifier,
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw AgentError.configurationInvalid(
                    "Image data does not match its declared MIME type \(declaredMIMEType)"
                )
            }
            return decoded
        }
    }
#endif
