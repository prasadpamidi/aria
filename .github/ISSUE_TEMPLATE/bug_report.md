---
name: Bug report
about: Aria misbehaves — agent stalls, tool fails, provider drops a stream, etc.
title: ''
labels: bug
assignees: ''
---

**What did you try to do?**
<!-- One sentence — the goal. e.g. "Run a tool-calling agent against OpenAI." -->

**What happened instead?**
<!-- The actual behaviour. Quote the failure mode exactly; paste the error
     string verbatim if you have one. -->

**Repro**
<!-- The smallest Swift snippet (or `swift run AriaCLI` invocation) that
     triggers the bug. Less is more — we'd rather fix a 10-line example
     than guess at a 100-line one. -->

```swift
// minimal repro
```

**Environment**

- Aria version: <!-- e.g. 0.1.3 or commit SHA -->
- Swift toolchain: <!-- `swift --version` output -->
- Platform: <!-- macOS / iOS / Linux, version -->
- Trait flags: <!-- `MLX`, `VoiceKokoro`, none -->
- LLM provider: <!-- FoundationModels / MLX / OpenAI / Anthropic / Gemini -->

**Logs**
<!-- swift-log output, OSLog dump, or AriaCLI stderr. Wrap in a
     <details> block if it's long. -->

<details>
<summary>Logs</summary>

```
paste here
```

</details>

**Anything else?**
<!-- Workarounds you tried, related issues, "this used to work in 0.1.x." -->
