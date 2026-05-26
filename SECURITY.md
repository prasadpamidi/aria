# Security Policy

## Supported Versions

Aria is pre-1.0; the latest tagged release is the only one that
receives security fixes. Older tags are kept for archival /
reproducibility only.

| Version | Supported |
| ------- | --------- |
| Latest 0.1.x | ✅ |
| < 0.1.0 | ❌ (deprecated, no fixes) |

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security
reports.** Public disclosure before a fix is shipped puts every
consumer of the SDK at risk.

Report to **security@prasadpamidi.dev** with:

- A description of the issue and the impact.
- A minimal reproduction (a Swift snippet, a sample input, or a
  reference to a specific commit + function).
- Your assessment of severity, if you have one (low / medium /
  high / critical).
- Whether you'd like to be credited in the advisory.

We aim to acknowledge new reports within **3 business days** and
ship a fix within **30 days** for high / critical issues.

## What's in scope

- `Sources/Aria/` — the platform-agnostic core layers (1–6).
- `Sources/AriaApple/`, `AriaTools/`, `AriaToolsJS/`,
  `AriaVoice/`, `AriaMLX/`, `AriaVoiceKokoro/`, `WorkflowKit/`,
  `AgentKit/` — every shipped target.
- The `JSContext`-sandboxed plugin runtime in `AriaToolsJS`.
  Sandbox-escape findings are explicitly in scope.
- Credential handling paths that touch `CapabilityBroker` /
  `CredentialStore`.

## What's out of scope

- Vulnerabilities in upstream Swift / Apple platform code (report
  to Apple directly).
- Vulnerabilities in third-party dependencies — `swift-log`,
  `swift-collections`, `mlx-swift-lm`, `kokoro-ios`, etc. Report
  to those projects upstream; we'll bump the dependency once
  they ship a fix.
- Issues that require a malicious operator to ship a hostile
  plugin / workflow / skill to their own users. (The threat model
  for plugins is "host app controls what's installed"; we don't
  defend against the user choosing to install something malicious
  they trust.)
- Theoretical / academic crypto-grade hardening claims. Aria
  isn't a security boundary by itself; the LLM-provider keys
  live in the host app's Keychain and we don't proxy them.

## Disclosure

Once a fix lands and the patched release is out, we'll publish a
GitHub Security Advisory crediting the reporter (if they
consented). For low-impact issues we may consolidate into a
regular release note instead of a dedicated advisory.
