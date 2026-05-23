# SPM Traits

Aria uses [package traits](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0480-package-traits.md)
(SE-0480, Swift 6.1+) to gate code paths whose dependencies are
heavy enough that consumers who don't need them shouldn't pay the
build / link cost.

## What aria gates

| Trait | Off by default | Gates | Pulls in |
| --- | --- | --- | --- |
| `MLX` | yes | `AriaMLX` target body | `mlx-swift-lm`, `swift-huggingface-mlx`, `swift-transformers-mlx` |
| `VoiceKokoro` | yes | `AriaVoiceKokoro` target body | `kokoro-ios`, `mlx-swift`, `MLXUtilsLibrary` |

Each trait declares a compile-time define (`ARIA_MLX`,
`ARIA_VOICE_KOKORO`) via `swiftSettings`. The trait-gated targets
wrap their source files in `#if ARIA_MLX` / `#if ARIA_VOICE_KOKORO`,
so the target compiles to an empty module when the trait is off.

## Enabling traits from a consumer Package.swift

```swift
.package(
    url: "https://github.com/prasadpamidi/aria.git",
    from: "0.1.0",
    traits: ["MLX", "VoiceKokoro"]
)
```

Order doesn't matter; either trait can be enabled independently.

## Enabling traits from an Xcode project

When adding aria via **File -> Add Package Dependencies...**, Xcode
shows the trait list with checkboxes once the URL resolves. Tick
the traits you want before clicking **Add Package**. To change the
selection on an already-added package, select aria under **Package
Dependencies** in the project settings — the trait checkboxes
appear in the right-hand pane.

## Resolution-time cost trade-off

SPM's `traits:` argument forwards traits to the target package; it
does **not** gate whether that package is resolved. Aria's
`Package.swift` keeps the MLX and Kokoro packages listed
unconditionally so a unified package layout works at all, and gates
the heavy work two layers deeper:

1. **Target dependency layer** — `.product(...)` declarations use
   `condition: .when(traits: ["MLX"])` so unenabled-trait builds
   skip linking the products entirely.
2. **Source layer** — `#if ARIA_MLX` / `#if ARIA_VOICE_KOKORO`
   guards make every gated source file compile to empty when the
   define is absent.

The practical effect: every consumer pays the **resolution** cost
(packages show up in `Package.resolved`), but only consumers that
opt in pay the **compile + link** cost — which is the dominant cost
for `mlx-swift-lm`'s C++ backend.

## Adding a new trait

1. Add the trait to `package.traits` in `Package.swift`:

   ```swift
   .trait(name: "MyFeature", description: "Enable …")
   ```

2. Add the trait condition to every dependency the new target
   needs:

   ```swift
   .product(
       name: "MyHeavyDep",
       package: "my-heavy-dep",
       condition: .when(traits: ["MyFeature"])
   )
   ```

3. Add the compile-time define to `swiftSettings` for both the
   target and its test target so test code can guard against the
   same define:

   ```swift
   swiftSettings: [
       .define("ARIA_MY_FEATURE", .when(traits: ["MyFeature"]))
   ]
   ```

4. Wrap every source file that imports the heavy module in
   `#if ARIA_MY_FEATURE` / `#endif`.

5. Document the trait in the README's trait matrix and add a
   `package_build_<trait>` Fastlane lane so CI exercises the
   build-with-trait path.

## Why not separate packages?

Separate packages would skip the resolution cost too, but at the
expense of a fragmented release surface (three repos to tag in
lockstep, three `Package.resolved` entries for consumers).
Traits keep aria as one cohesive release while letting consumers
pay only for what they use. See
[`docs/decisions/`](decisions/) for the full rationale.
