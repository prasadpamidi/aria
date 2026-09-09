#if canImport(FoundationModels)
    import Aria
    import Foundation
    import FoundationModels
    import ImageIO

    @available(iOS 26.0, macOS 26.0, *)
    struct FoundationModelsPromptContent {
        // MARK: Internal

        let text: String
        let images: [ImageContent]

        var requiresVision: Bool {
            !self.images.isEmpty
        }

        func resolveImages() throws -> [CGImage] {
            try self.images.map(Self.makeCGImage)
        }

        // MARK: Fileprivate

        fileprivate static func makeCGImage(for image: ImageContent) throws -> CGImage {
            switch image.source {
            case let .data(data, _):
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw AgentError.configurationInvalid(
                        "FoundationModels image data must contain a valid image"
                    )
                }
                return cgImage
            case let .url(url):
                guard url.isFileURL else {
                    throw AgentError.configurationInvalid(
                        "FoundationModels image URL must be a local file URL"
                    )
                }
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw AgentError.configurationInvalid(
                        "FoundationModels image URL must reference a valid image"
                    )
                }
                return cgImage
            case .identifier:
                throw AgentError.configurationInvalid(
                    "FoundationModels cannot resolve an image identifier; provide image data or a local file URL"
                )
            }
        }
    }

    #if compiler(>=6.4)
        @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
        @available(tvOS, unavailable)
        extension FoundationModelsPromptContent {
            func makePrompt(images: [CGImage]) -> FoundationModels.Prompt {
                let attachments = images.map { Attachment<ImageAttachmentContent>($0) }
                return FoundationModels.Prompt {
                    self.text
                    attachments
                }
            }
        }
    #endif
#endif
