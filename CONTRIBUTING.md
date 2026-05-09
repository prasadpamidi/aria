# Contributing to Aria

Thanks for your interest in contributing. Aria is in early architecture/design phase; the protocols and types described in `docs/layers/` are the target design, and implementation is pending.

## Before you contribute

1. **Read [NOTICE.md](NOTICE.md).** Aria is a clean-room implementation. Do not copy code, documentation, or naming conventions from LangChain.js, LangGraph.js, Python LangChain, LlamaIndex, AutoGen, CrewAI, or any other agent/LLM framework. If a snippet looks like it might be derived from another framework, do not include it.
2. **Read [AGENTS.md](AGENTS.md).** The conventions, build commands, and architectural rules apply to all contributors, human or AI-assisted.
3. **Read the relevant layer doc** in `docs/layers/` for the area you are touching.

## Contribution flow

1. **Open an issue first** for non-trivial changes. Aria's design favors small, focused additions; surprise mega-PRs are unlikely to merge.
2. **Branch off `main`.** Use a descriptive branch name (`feat/foundation-message`, `fix/runnable-pipe-edge-case`).
3. **Write tests.** New public APIs require tests. Tests for `Aria` must run on Linux.
4. **Verify the platform boundary.** If you touched `Aria`, confirm `swift build --target Aria` succeeds on Linux (CI checks this).
5. **Open a PR.** Reference the relevant docs and explain the design choice in the description.
6. **One reviewer minimum.** Maintainer review for changes that touch the public API or `docs/decisions/`.

## Code style

See [AGENTS.md](AGENTS.md) for the full style guide. Highlights:

- 4-space indentation, no tabs.
- `///` doc comments on all public APIs.
- No emoji in code, comments, or commit messages.
- One type per file for non-trivial types.
- Imperative-mood commit messages.

## Tests

```bash
swift test                          # all tests
swift test --filter AriaTests       # core only (Linux-safe)
```

Use `MockLLMProvider` and `HashEmbedder` from `AriaTesting` for deterministic tests. No live network calls.

## Documentation

Documentation lives in `docs/` and is the source of truth for the architecture. If your change diverges from docs, update one of them in the same PR.

When adding a new architectural decision, add an ADR in `docs/decisions/` with the next sequential number, status, date, context, decision, rationale, consequences, and alternatives.

## IP and originality

If you use AI assistance (Claude, Copilot, Cursor, etc.), ensure:

- The AI was not instructed to "copy", "port", or "translate" code from a named third-party framework.
- The output is a Swift-native expression of generic patterns, not a transliteration of a specific framework's code.
- Comments do not credit specific framework source files; they cite generic patterns or papers.

If you are unsure, refuse and ask in the PR.

## License

By contributing, you agree your contribution is licensed under the [MIT License](LICENSE).
