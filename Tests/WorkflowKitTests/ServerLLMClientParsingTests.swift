import Foundation
import Testing
@testable import WorkflowKit

// MARK: - ServerLLMClientParsingTests

/// Pin the response-body parsing contracts for each vendor
/// client. Network behaviour is uninteresting to test here —
/// what matters is that when the wire shape arrives intact we
/// extract the right text, and when it doesn't we throw a
/// `ServerLLMError.malformedResponse` with a useful message.
struct ServerLLMClientParsingTests {
    @Test
    func openAIParsesChoicesMessageContent() throws {
        let payload = """
        {
          "id": "chatcmpl-1",
          "choices": [
            {"message": {"role": "assistant", "content": "ok"}}
          ]
        }
        """
        let data = Data(payload.utf8)
        let text = try OpenAIWorkflowLLMProvider.parseContent(from: data)
        #expect(text == "ok")
    }

    @Test
    func openAIThrowsWhenChoicesMissing() {
        let data = Data("{\"error\": {\"message\": \"nope\"}}".utf8)
        #expect(throws: ServerLLMError.self) {
            try OpenAIWorkflowLLMProvider.parseContent(from: data)
        }
    }

    // MARK: Anthropic

    @Test
    func anthropicJoinsTextBlocksInOrder() throws {
        let payload = """
        {
          "id": "msg_1",
          "type": "message",
          "content": [
            {"type": "text", "text": "first "},
            {"type": "text", "text": "second"}
          ]
        }
        """
        let data = Data(payload.utf8)
        let text = try AnthropicWorkflowLLMProvider.parseContent(from: data)
        #expect(text == "first second")
    }

    @Test
    func anthropicThrowsOnEmptyContent() {
        let data = Data("{\"content\": []}".utf8)
        #expect(throws: ServerLLMError.self) {
            try AnthropicWorkflowLLMProvider.parseContent(from: data)
        }
    }

    // MARK: Gemini

    @Test
    func geminiParsesCandidatesParts() throws {
        let payload = """
        {
          "candidates": [
            {"content": {"parts": [{"text": "hello"}, {"text": " world"}]}}
          ]
        }
        """
        let data = Data(payload.utf8)
        let text = try GeminiWorkflowLLMProvider.parseContent(from: data)
        #expect(text == "hello world")
    }

    @Test
    func geminiSurfacesPromptFeedbackBlockReason() {
        let payload = """
        {
          "promptFeedback": {"blockReason": "SAFETY"}
        }
        """
        let data = Data(payload.utf8)
        #expect(throws: ServerLLMError.self) {
            try GeminiWorkflowLLMProvider.parseContent(from: data)
        }
    }
}
