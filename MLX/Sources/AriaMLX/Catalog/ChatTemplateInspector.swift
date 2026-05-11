#if canImport(MLXLMCommon)
    import Foundation

    // MARK: - ChatTemplateInspector

    /// Detect whether a model's chat template understands `tools` by
    /// scanning the `chat_template` Jinja in `tokenizer_config.json`.
    ///
    /// Hugging Face has no canonical "supports_tools" field, so the most
    /// reliable runtime signal is checking for `tools`/`tool_calls`
    /// references in the template itself. Used as a fallback for
    /// user-added models that aren't in `MLXModelCatalog`.
    public enum ChatTemplateInspector {
        /// Inspect the model directory's `tokenizer_config.json` for
        /// tool-call references. Returns `false` on any I/O or parse
        /// error — better to silently disable tools than crash a chat.
        public static func detectToolSupport(in modelDirectory: URL) -> Bool {
            let configURL = modelDirectory.appendingPathComponent("tokenizer_config.json")
            guard let data = try? Data(contentsOf: configURL),
                  let parsed = try? JSONSerialization.jsonObject(with: data),
                  let dict = parsed as? [String: Any],
                  let template = dict["chat_template"] as? String else {
                return false
            }
            return Self.templateReferencesTools(template)
        }

        /// Public for unit testing — given a Jinja chat template string,
        /// returns whether it appears to support tool calls.
        public static func templateReferencesTools(_ template: String) -> Bool {
            // Conservative: any reference to a `tools` Jinja variable, a
            // `tool_calls` field on a message, or the literal token
            // `<tool_call>` indicates tool support. False positives are
            // benign (we'd advertise tools the model can't reliably use)
            // but false negatives would silently disable tooling, so err
            // toward "yes".
            let needles = [
                "tool_call", // covers tool_call / tool_calls / <tool_call>
                "tools",
                "<|python_tag|>",
                "[TOOL_CALLS]",
            ]
            return needles.contains { template.contains($0) }
        }
    }
#endif
