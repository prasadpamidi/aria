# Aria — Architecture & Design

**Aria** is a composable, on-device agent runtime for Apple platforms, with a platform-agnostic core designed to extend to other platforms over time.

This folder is the source of truth for how Aria is structured and why.

## Reading order

If you are new to the project, read in this order:

1. [overview.md](overview.md) — what Aria is, who it is for, what problem it solves
2. [principles.md](principles.md) — the architectural rules everything follows
3. [architecture.md](architecture.md) — the layered design and module layout
4. [platform-boundary.md](platform-boundary.md) — the cross-platform discipline

Then read layer by layer:

5. [layers/01-foundation.md](layers/01-foundation.md) — value types, events, errors
6. [layers/02-runnable.md](layers/02-runnable.md) — the composability primitive
7. [layers/03-providers.md](layers/03-providers.md) — LLMProvider, Tool, Embedder
8. [layers/04-memory.md](layers/04-memory.md) — history, checkpoints, vectors, long-term store
9. [layers/05-agent.md](layers/05-agent.md) — the tool-calling agent loop
10. [layers/06-stategraph.md](layers/06-stategraph.md) — optional graph orchestration

Then the two consumer-facing runtimes that compose Layers 1–6:

11. [workflowkit.md](workflowkit.md) — recipes you write (deterministic workflows)
12. [agentkit.md](agentkit.md) — goals you delegate (open-ended agents)

And the orthogonal feature areas:

13. [skills.md](skills.md) — Anthropic-style instruction bundles
14. [plugins.md](plugins.md) — JS plugin tools (`.aria-tool` runtime)
15. [traits.md](traits.md) — SPM traits (MLX, VoiceKokoro)
16. [observability.md](observability.md) — OTel tracing/metrics + session record/replay

Decision records (the "why" behind major architectural choices):

- [decisions/0001-native-swift-vs-js.md](decisions/0001-native-swift-vs-js.md)
- [decisions/0002-platform-agnostic-core.md](decisions/0002-platform-agnostic-core.md)
- [decisions/0003-runnable-as-foundation.md](decisions/0003-runnable-as-foundation.md)
- [decisions/0004-protocol-first-design.md](decisions/0004-protocol-first-design.md)
- [decisions/0005-streaming-as-default.md](decisions/0005-streaming-as-default.md)

Terminology:

- [glossary.md](glossary.md)

## Status

This is a design document. Implementation has not yet begun. The protocols, types, and module layout described here are the target architecture, not present-day code. Code samples are illustrative — they show intent and shape, not finished implementation.
