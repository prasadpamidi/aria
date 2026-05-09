# ADR 0001 — Build native Swift, do not embed LangChain.js

**Status:** Accepted
**Date:** 2026-05-09

## Context

Apple's FoundationModels (iOS 26+), MLX, and Core ML give iOS apps high-quality on-device LLM inference. To make use of these models in agentic applications, we need a runtime that handles:

- Tool calling and the agent control loop
- Streaming output to UI
- Memory (chat history, checkpoints, vector recall)
- Composition of prompts, models, and parsers
- Optional graph orchestration for multi-step workflows

Two paths were considered:

1. **Embed LangChain.js inside JavaScriptCore** — bundle the LangChain.js runtime in JSC, bridge to Swift LLM adapters via `JSExport`, write the application's agent logic in JavaScript.
2. **Build a native Swift library** — design and implement a small, opinionated agent framework directly in Swift.

A feasibility audit of LangChain.js was conducted to inform the decision.

## What the audit found

LangChain.js's core (`@langchain/core`) is not directly executable in JavaScriptCore. The blockers:

- Hard import of `node:async_hooks` in `libs/langchain-core/src/context.ts` and the callbacks dispatch system. JSC has no equivalent. The MockAsyncLocalStorage fallback exists but the bare import would fail at module-load time before any fallback could engage.
- Default tracing path through `langsmith`, which has Node-specific code paths.
- Tokenizer data fetch (`tiktoken.pages.dev`) requires `fetch`, which JSC lacks.
- No browser/RN export condition — bundling for JSC requires manual aliasing in Metro/esbuild.

These are tractable with patches and stubs (~1–2 weeks of integration work), but they leave a maintenance trail every time LangChain.js evolves.

The audit also identified that **the parts of LangChain.js that matter for on-device agents are a small fraction of the library**. The agent loop, tool definitions, streaming events, and memory protocols are roughly 5% of LangChain's surface area; the other 95% (vendor integrations, server patterns, multi-LLM compatibility shims) does not apply on-device.

## Decision

Build native Swift.

## Rationale

1. **The Pareto-optimal target is small.** A native implementation focused on what matters for on-device iOS is a few thousand lines of Swift, not tens of thousands. The "LangChain is a huge library" advantage is largely irrelevant when 95% of it is server-shaped.

2. **Native ergonomics are meaningfully better.** Swift's `AsyncSequence`, actors, `@Generable`, and type-safe tool I/O produce code that is easier to read, debug, and test than the bridged-JS equivalent. The cost of an embedded JS runtime — bundle size, memory, parsing, debugger isolation — is real and recurring.

3. **FoundationModels covers the LLM layer cleanly.** Apple's `Tool` protocol and `@Generable` types give us type-safe tool calling without LangChain's abstractions. Our framework orchestrates above that layer; we do not need LangChain's vendor-shim machinery.

4. **The agent control loop is converged.** The ReAct/tool-calling pattern has been stable for over a year. We are not betting on a moving target; we are implementing a known pattern in our preferred language.

5. **Cross-platform potential is preserved.** A platform-agnostic Swift core (`Aria` target, Linux-buildable) keeps the door open to Android via Skip, KMP wrappers, or the official Swift Android toolchain. The JSC route also offers cross-platform, but the bridge tax recurs on every platform.

6. **Maintenance burden is bounded.** LangChain's velocity is on integrations and server features. The agent loop changes slowly. Maintaining our own ~3k-line library is cheaper than tracking LangChain's release cadence and keeping our patches alive.

## Consequences

### Positive

- Native debugging with breakpoints, instruments, the works.
- Type safety end-to-end; compile-time errors instead of runtime ones.
- Smaller app binary (no embedded JS runtime).
- Faster cold start (no JS parsing).
- No vendor-shim complexity — one provider abstraction, two or three platform implementations.

### Negative

- We do not get LangChain's ecosystem of integrations for free. We implement what we need (a few vector stores, a few embedders, the tools we use).
- We bear maintenance for our own library.
- We cannot hot-reload agent logic over the air (would require shipping new app builds).

### Mitigations

- Keep the library small and the surface area narrow. See the principles in `docs/principles.md`.
- Use protocols + dependency injection so swappable parts (providers, embedders, vector stores) are easy to replace.
- Build a robust test suite from day one so refactors are safe.
- If hot-reload becomes critical, expose a constrained scripting surface (e.g., user-defined tools as JSON-config + a small DSL) rather than embedding a full JS runtime.

## Alternatives considered

### A. Embed LangChain.js in JSC
Discussed above. Rejected for ergonomics, bundle size, and ongoing patch maintenance.

### B. Wrap LangChain.js Python via PythonKit
Adds a Python runtime to the iOS app. Worse than the JSC option on every dimension.

### C. Reimplement the absolute minimum (no library at all)
Each feature implements its own ad-hoc agent loop. Rejected because it leads to inconsistent agent behavior across features and duplicated code.

### D. Use a vendor-locked SDK exclusively (e.g., Apple Intelligence APIs)
Locks us to one model. Rejected because a key requirement is supporting MLX and Core ML alongside FoundationModels.

## Independence statement

Aria is an independent design and implementation. The architecture is informed by publicly-discussed agent patterns (ReAct loops, tool calling, state graphs, checkpointing) and by an audit of LangChain.js's source for *feasibility analysis only*. No code, documentation, or naming convention has been or will be copied from LangChain.js, LangGraph.js, or any other framework. Generic terms (`Runnable`, `Tool`, `Channel`, `StateGraph`) are used because they are standard names in computer science and software engineering, predating their use in any specific framework.
