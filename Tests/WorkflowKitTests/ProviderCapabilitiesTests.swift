import Aria
import Foundation
import Testing
@testable import WorkflowKit

// MARK: - WorkflowProviderCapabilitiesTests

@Suite("WorkflowProviderCapabilities")
struct WorkflowProviderCapabilitiesTests {
    @Test("Conservative default advertises text-only, no streaming, no mid-turn tools")
    func conservativeDefault() {
        let caps = WorkflowProviderCapabilities.conservative
        #expect(caps.supportsStructuredOutput == false)
        #expect(caps.supportsStreamingStructured == false)
        #expect(caps.supportsMidTurnTools == false)
        #expect(caps.supportedModalities == [.text])
        #expect(caps.supportsCancellation == true)
        #expect(caps.maxContextTokens == nil)
        #expect(caps.maxOutputTokens == nil)
    }

    @Test("with(...) builder copies untouched fields")
    func withBuilderCopiesUntouched() {
        let base = WorkflowProviderCapabilities(
            supportsStructuredOutput: true,
            supportsStreamingStructured: false,
            supportedModalities: [.text, .image],
            maxContextTokens: 8_000
        )
        let next = base.with(streamingStructured: true)
        #expect(next.supportsStructuredOutput == true) // preserved
        #expect(next.supportsStreamingStructured == true) // changed
        #expect(next.supportedModalities == [.text, .image]) // preserved
        #expect(next.maxContextTokens == 8_000) // preserved
    }

    @Test("Existing providers inherit conservative defaults — no source changes required")
    func existingProvidersInheritDefaults() {
        struct LegacyProvider: WorkflowLLMProvider {
            func generate(
                prompt _: String, hint _: ModelFamilyHint, maxTokens _: Int?
            ) async throws -> String { "ok" }
        }
        let provider = LegacyProvider()
        // Untouched provider gets `.conservative` via default
        // protocol extension — the cornerstone of the 0.2.x
        // backwards-compatibility promise.
        #expect(provider.capabilities == .conservative)
    }

    @Test("Providers can opt in to richer capabilities via override")
    func providerOptsInToRicher() {
        struct ModernProvider: WorkflowLLMProvider {
            var capabilities: WorkflowProviderCapabilities {
                WorkflowProviderCapabilities(
                    supportsStructuredOutput: true,
                    supportsStreamingStructured: true,
                    supportedModalities: [.text, .image]
                )
            }
            func generate(
                prompt _: String, hint _: ModelFamilyHint, maxTokens _: Int?
            ) async throws -> String { "ok" }
        }
        let provider = ModernProvider()
        #expect(provider.capabilities.supportsStreamingStructured == true)
        #expect(provider.capabilities.supportedModalities.contains(.image))
    }

    @Test("ContentModality enumerates every value used by LLMStep.requiredModalities")
    func contentModalityCovers() {
        let all = Set(ContentModality.allCases)
        #expect(all.contains(.text))
        #expect(all.contains(.image))
        #expect(all.contains(.audio))
        #expect(all.contains(.file))
        #expect(all.contains(.video))
    }
}
