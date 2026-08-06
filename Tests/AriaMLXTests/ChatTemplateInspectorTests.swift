#if ARIA_MLX
    #if canImport(MLXLMCommon)
        import XCTest
        @testable import AriaMLX

        final class ChatTemplateInspectorTests: XCTestCase {
            func testDetectsQwenStyleToolTemplate() {
                // Trimmed Qwen-family chat template — references `tools`,
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

            /// Every mlx-community LFM2.5 conversion ships its template
            /// as a standalone `chat_template.jinja` with no
            /// `chat_template` key in `tokenizer_config.json`. Reading
            /// only the JSON reports "no tools" and silently disables
            /// tooling for these models.
            func testDetectsToolsFromStandaloneJinjaFile() throws {
                let dir = try Self.makeTempDir()
                defer { try? FileManager.default.removeItem(at: dir) }

                // Shape of the real LFM2.5 template: tools injected
                // into the system prompt, no `chat_template` in JSON.
                try #"{%- if tools -%}{{- "List of tools: [" -}}{%- endif -%}"#
                    .write(
                        to: dir.appendingPathComponent("chat_template.jinja"),
                        atomically: true,
                        encoding: .utf8
                    )
                try #"{"bos_token": "<|startoftext|>"}"#
                    .write(
                        to: dir.appendingPathComponent("tokenizer_config.json"),
                        atomically: true,
                        encoding: .utf8
                    )

                XCTAssertTrue(ChatTemplateInspector.detectToolSupport(in: dir))
            }

            /// The standalone file wins when a repo ships both, since
            /// it is the newer of the two by convention.
            func testStandaloneJinjaTakesPrecedenceOverTokenizerConfig() throws {
                let dir = try Self.makeTempDir()
                defer { try? FileManager.default.removeItem(at: dir) }

                try "{% for msg in messages %}{{ msg.content }}{% endfor %}"
                    .write(
                        to: dir.appendingPathComponent("chat_template.jinja"),
                        atomically: true,
                        encoding: .utf8
                    )
                try #"{"chat_template": "{% if tools %}<tool_call>{% endif %}"}"#
                    .write(
                        to: dir.appendingPathComponent("tokenizer_config.json"),
                        atomically: true,
                        encoding: .utf8
                    )

                XCTAssertFalse(
                    ChatTemplateInspector.detectToolSupport(in: dir),
                    "Standalone jinja (text-only) should win over the stale JSON key"
                )
            }

            /// The original layout must keep working — an empty or
            /// absent jinja file falls through to the JSON key.
            func testFallsBackToTokenizerConfigWhenJinjaAbsent() throws {
                let dir = try Self.makeTempDir()
                defer { try? FileManager.default.removeItem(at: dir) }

                try #"{"chat_template": "{% if tools %}<tool_call>{% endif %}"}"#
                    .write(
                        to: dir.appendingPathComponent("tokenizer_config.json"),
                        atomically: true,
                        encoding: .utf8
                    )

                XCTAssertTrue(ChatTemplateInspector.detectToolSupport(in: dir))
            }

            // MARK: Private

            private static func makeTempDir() throws -> URL {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("mlx-test-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                return dir
            }
        }
    #endif
#endif
