#if canImport(FoundationModels)
    import Aria
    import Foundation
    import FoundationModels

    @available(iOS 26.0, macOS 26.0, *)
    enum FoundationModelsErrorMapper {
        // MARK: Internal

        static func map(_ error: any Error) -> AgentError {
            if error is CancellationError {
                return .cancelled
            }
            if let agentError = error as? AgentError {
                return agentError
            }

            #if compiler(>=6.4)
                if #available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *),
                   let mapped = mapCurrent(error) {
                    return mapped
                }
            #endif

            if let error = error as? LanguageModelSession.GenerationError {
                return self.mapLegacy(error)
            }
            return self.rejected(.unknown, error)
        }

        static func mapUnavailable(
            _ reason: SystemLanguageModel.Availability.UnavailableReason
        ) -> AgentError {
            switch reason {
            case .deviceNotEligible, .appleIntelligenceNotEnabled:
                return self.rejected(
                    .providerUnavailable,
                    message: "Foundation Models is unavailable: \(String(describing: reason))"
                )
            case .modelNotReady:
                return self.rejected(
                    .assetsUnavailable,
                    message: "Foundation Models assets are not ready"
                )
            @unknown default:
                return self.rejected(
                    .providerUnavailable,
                    message: "Foundation Models availability is unknown"
                )
            }
        }

        // MARK: Private

        private static func mapLegacy(
            _ error: LanguageModelSession.GenerationError
        ) -> AgentError {
            let kind: ProviderFailureKind =
                switch error {
                case .exceededContextWindowSize:
                    .contextWindowExceeded
                case .assetsUnavailable:
                    .assetsUnavailable
                case .guardrailViolation, .refusal:
                    .safetyRejected
                case .unsupportedGuide:
                    .unsupportedGenerationGuide
                case .unsupportedLanguageOrLocale:
                    .unsupportedLanguageOrLocale
                case .decodingFailure:
                    .invalidOutput
                case .rateLimited:
                    .rateLimited
                case .concurrentRequests:
                    .sessionConflict
                @unknown default:
                    .unknown
                }
            return self.rejected(kind, error)
        }

        #if compiler(>=6.4)
            @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
            private static func mapCurrent(_ error: any Error) -> AgentError? {
                if let error = error as? LanguageModelError {
                    let kind: ProviderFailureKind =
                        switch error {
                        case .contextSizeExceeded:
                            .contextWindowExceeded
                        case .rateLimited:
                            .rateLimited
                        case .guardrailViolation, .refusal:
                            .safetyRejected
                        case .unsupportedCapability:
                            .unsupportedCapability
                        case .unsupportedTranscriptContent:
                            .unsupportedTranscript
                        case .unsupportedGenerationGuide:
                            .unsupportedGenerationGuide
                        case .unsupportedLanguageOrLocale:
                            .unsupportedLanguageOrLocale
                        case .timeout:
                            .timedOut
                        @unknown default:
                            .unknown
                        }
                    return self.rejected(kind, error)
                }
                if let error = error as? SystemLanguageModel.Error {
                    switch error {
                    case .assetsUnavailable:
                        return self.rejected(.assetsUnavailable, error)
                    @unknown default:
                        return self.rejected(.unknown, error)
                    }
                }
                if let error = error as? LanguageModelSession.Error {
                    switch error {
                    case .concurrentRequests:
                        return self.rejected(.sessionConflict, error)
                    case .transcriptMutationWhileResponding:
                        return self.rejected(.transcriptMutation, error)
                    @unknown default:
                        return self.rejected(.unknown, error)
                    }
                }
                return nil
            }
        #endif

        private static func rejected(
            _ kind: ProviderFailureKind,
            _ error: any Error
        ) -> AgentError {
            let underlying = ErrorBox(error)
            return .providerRejected(.init(
                kind: kind,
                message: underlying.message,
                underlying: underlying
            ))
        }

        private static func rejected(
            _ kind: ProviderFailureKind,
            message: String
        ) -> AgentError {
            .providerRejected(.init(kind: kind, message: message))
        }
    }
#endif
