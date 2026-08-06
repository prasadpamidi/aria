#if ARIA_MLX
    import Foundation

    // MARK: - ChatTemplateInspector

    /// Detect whether a model's chat template understands `tools` by
    /// scanning the model's Jinja chat template.
    ///
    /// Hugging Face has no canonical "supports_tools" field, so the most
    /// reliable runtime signal is checking for `tools`/`tool_calls`
    /// references in the template itself. Used as a fallback for
    /// user-added models that aren't in `MLXModelCatalog`.
    ///
    /// Two on-disk layouts are supported. The original embeds the
    /// template as a `chat_template` string inside
    /// `tokenizer_config.json`; the newer convention ships a
    /// standalone `chat_template.jinja` and drops the JSON key
    /// entirely. Repos using only the latter — every mlx-community
    /// LFM2.5 conversion, for one — would otherwise read as "no tool
    /// support" and have tooling silently disabled.
    public enum ChatTemplateInspector {
        // MARK: Public

        /// Inspect the model directory for tool-call references in
        /// its chat template. Returns `false` on any I/O or parse
        /// error — better to silently disable tools than crash a chat.
        public static func detectToolSupport(in modelDirectory: URL) -> Bool {
            guard let template = loadTemplate(in: modelDirectory) else {
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

        // MARK: Internal

        /// Read the model's chat template from whichever of the two
        /// supported layouts is present, preferring the standalone
        /// `chat_template.jinja`. When a repo ships both, the
        /// standalone file is the newer of the two by convention.
        static func loadTemplate(in modelDirectory: URL) -> String? {
            let jinjaURL = modelDirectory.appendingPathComponent("chat_template.jinja")
            if let jinja = try? String(contentsOf: jinjaURL, encoding: .utf8),
               !jinja.isEmpty {
                return jinja
            }

            let configURL = modelDirectory.appendingPathComponent("tokenizer_config.json")
            guard let data = try? Data(contentsOf: configURL),
                  let parsed = try? JSONSerialization.jsonObject(with: data),
                  let dict = parsed as? [String: Any],
                  let template = dict["chat_template"] as? String else {
                return nil
            }
            return template
        }
    }
#endif
