# Notice — Independence and Clean-Room Statement

Aria is an independent design and implementation. It is not derived from, and does not contain code lifted from, LangChain.js, LangGraph.js, Python LangChain, LlamaIndex, or any other agent or LLM framework.

## What this means in practice

- **No code copying.** No source file in this repository has been or will be copy-pasted, transliterated, or "ported" line-by-line from another framework's source code.
- **No documentation copying.** No documentation in this repository has been or will be copy-pasted from another framework's documentation.
- **No internal class structure mirroring.** While Aria's protocols and types serve similar purposes to those in other frameworks, their shapes, semantics, and Swift-native expressions are independently designed.
- **Generic terminology is used because it is generic.** Names like `Runnable`, `Tool`, `Channel`, `StateGraph`, `Embedder`, `Checkpointer`, and `MemoryStore` are standard terms in computer science and software engineering. Aria uses them in their conventional senses, not because any particular framework uses them.

## What informed the design

The design was informed by:

- **Public, peer-reviewed literature** on agent patterns (ReAct, tool calling, planner-executor patterns, Pregel-style graph computation).
- **Apple's published frameworks and APIs** — FoundationModels, MLX, Core ML, NaturalLanguage, SwiftData, swift-log, swift-collections.
- **A feasibility audit of LangChain.js's source** conducted before any implementation work began. The audit examined module structure and dependency surface to determine whether LangChain.js could be embedded in JavaScriptCore. The conclusion (see [docs/decisions/0001-native-swift-vs-js.md](docs/decisions/0001-native-swift-vs-js.md)) was to **not embed LangChain.js** and to write a native Swift library instead. The audit produced no copied artifacts; it produced a feasibility report.
- **Swift language idioms and conventions** — protocol-oriented design, Swift Concurrency, `Sendable`, `AsyncSequence`, `Codable`.

## Contributor expectations

If you contribute to Aria:

- Do not paste code from other agent frameworks (LangChain, LangGraph, LlamaIndex, AutoGen, CrewAI, etc.) into this repository.
- Do not paste documentation, comments, or tests from other frameworks.
- If you reference a public design pattern (e.g., ReAct), cite the original paper or a textbook discussion, not a specific framework's implementation.
- If your contribution was assisted by an AI tool, ensure the AI was not instructed to "copy" or "port" from a specific named framework's source.

## License

Aria is MIT-licensed (see [LICENSE](LICENSE)). This permits broad use including commercial use, derivative works, and inclusion in larger projects. The clean-room statement above is independent of license: it describes how Aria is built, not how it may be used.
