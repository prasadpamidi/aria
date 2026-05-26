<!--
  Thanks for sending a PR. The questions below are the ones a
  reviewer asks anyway; answering them here saves a round-trip.
  Delete sections that don't apply.
-->

## What

<!-- 1–3 sentences. The change in plain English. -->

## Why

<!-- The user-visible problem this fixes, or the design tension
     it resolves. Skip "because it's a good idea" — say *whose*
     life gets better. -->

## How

<!-- Architecture notes. Where the change lives (layer / target),
     what protocol / public API surface it touches, whether it
     changes the dependency graph or the trait story. -->

## Risk

<!-- The most likely way this regresses something. Be honest. -->

## Verification

- [ ] `swift build` (default traits) is clean
- [ ] `swift build --traits MLX,VoiceKokoro` is clean
- [ ] `swift test` is green
- [ ] `bundle exec fastlane quality` is clean
- [ ] Linux CI (`Tests/AriaTests`) still builds — required if anything
      under `Sources/Aria/` changed
- [ ] Docs touched if public API changed (`docs/`, `README.md`,
      relevant `docs/layers/*.md`, `docs/glossary.md`)
- [ ] `CHANGELOG.md` updated under `[Unreleased]`

## Breaking changes

<!-- "None" or list each break + the migration path. Pre-1.0
     breaking changes are fine but they need to be documented. -->

## Related issues

<!-- "Closes #N", "Refs #N", etc. -->
