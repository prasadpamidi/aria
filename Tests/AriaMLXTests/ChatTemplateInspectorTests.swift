#if canImport(MLXLMCommon)
    import XCTest
    @testable import AriaMLX

    final class ChatTemplateInspectorTests: XCTestCase {
        func testDetectsQwenStyleToolTemplate() {
            // Trimmed Qwen 2.5 chat template — references `tools`,
            // `tool_calls`, and the `<tool_call>` literal.
            let template = """
            {% if tools %}
            # Tools
            {% for tool in tools %}
            ## {{ tool.function.name }}
            {% endfor %}
            {% endif %}
            {% if message.tool_calls %}
            <tool_call>{{ message.tool_calls[0] }}</tool_call>
            {% endif %}
            """
            XCTAssertTrue(ChatTemplateInspector.templateReferencesTools(template))
        }

        func testDetectsLlama3ToolTemplate() {
            let template = "{{ message.content }}{% if tool_calls %}<|python_tag|>{{ tool_calls }}{% endif %}"
            XCTAssertTrue(ChatTemplateInspector.templateReferencesTools(template))
        }

        func testRejectsBasicTextOnlyTemplate() {
            let template = "{% for msg in messages %}{{ msg.role }}: {{ msg.content }}\n{% endfor %}"
            XCTAssertFalse(ChatTemplateInspector.templateReferencesTools(template))
        }

        func testReturnsFalseWhenTokenizerConfigMissing() {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("mlx-test-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            XCTAssertFalse(ChatTemplateInspector.detectToolSupport(in: tempDir))
        }
    }
#endif
