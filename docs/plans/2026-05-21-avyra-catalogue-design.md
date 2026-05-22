# Avyra Catalogue — Prebuilt Workflows, Tools, and Templates

> Status: design. Not yet implemented.
> Companion docs:
> - `2026-05-20-avyra-workflows-design.md` (workflow runtime)
> - `2026-05-20-avyra-workflows-p0-plan.md` (P0 implementation plan)
> - `2026-05-21-avyra-skills-design.md` (skills + server-provider tool calling)

## 1. Strategic framing — the moat

Avyra is the only consumer AI app today that combines:

1. **HealthKit** reads (steps, sleep, HRV, workouts, water, menstrual cycle, body composition, …)
2. **Calendar + Reminders** access
3. **Local file** reads
4. **On-device LLM** as the default (Apple Intelligence + MLX models)
5. **Server LLM providers** (OpenAI / Anthropic / Gemini) as opt-ins
6. **Workflows + MCP + JS plugins** as extension surfaces
7. **Privacy guarantees** that match the App Store's strictest categories (no servers, no analytics, no account)

ChatGPT / Claude / Gemini apps don't read health data. Apple Shortcuts gives you HealthKit access but no LLM to interpret it. Whoop / Oura / Strava interpret a slice but don't talk to calendar / reminders. **Avyra is the only app where your personal AI knows YOU because YOUR data never has to leave to be useful.**

The catalogue (this doc) is how we convert that moat into instant user value. Without it, first-launch users see an empty workflow library and bounce. With it, they see actual workflows acting on their actual data within 5 seconds.

## 2. Three product layers

| Layer | What | Who builds it | Where it shows |
|---|---|---|---|
| **Prebuilt workflows** | Ready-to-run, interprets the user's data | First-party (us) | Workflow Gallery (new) |
| **JS plugin tools** | Atomic, model-called functions | First-party (us) | Auto-included in chat tools |
| **Templates** | Skeleton workflows + plugin starters + prompt snippets | First-party (us) | "New workflow" sheet + plugin authoring + snippet picker |

The unifying mechanism is `SeedContent` — see § 8.

## 3. The hook — 5-minute first-launch experience

Today: empty workflow list except `Daily Brief`. Bounce risk is high.

Target: Workflow Gallery on first launch, sorted by what's instantly possible (fewest permission grants first), grouped by category.

Onboarding sequence:

1. Splash screen — three pillars (private, knows you, ready to go).
2. **Workflow Gallery** opens — categories visible, ~60 workflows total.
3. User taps a card → permission flow runs inline if needed → workflow runs → output appears within 5 seconds.

**The wow moment**: tap *Daily Health Brief* → HealthKit permission sheet → 3 seconds → user reads *their own* sleep score interpreted by the model. That's a screenshot worth posting. Then they tap **Remix** and have their own editable copy.

## 4. Catalogue — 60+ prebuilt workflows in 7 packs

Each pack defines a marketable persona. Workflows are sorted within each pack by lowest permission cost first.

### Pack 1 · Daily Essentials (10) — universal, minimal permissions
- Morning Brief (calendar + reminders + optional weather via HTTP tool)
- End-of-Day Reflection
- Tip + Bill Splitter
- Tone Adjuster (paste text → 3 rewrites)
- Email Drafter (bullets → email)
- Quick Translation
- Concept Explainer (ELI5 / beginner / expert)
- Trip Packing List
- Recipe from Ingredients on Hand
- Meeting Notes Formatter (paste transcript → attendees / decisions / actions)

### Pack 2 · Health & Fitness (12) — Avyra's strongest moat
- Daily Health Brief (already seeded)
- Weekly Health Report (week-over-week trends)
- Sleep Coach (interprets sleep stages, suggests bedtime adjustments)
- Recovery Score (composite of sleep + HRV + activity)
- Workout Intensity Suggester (based on yesterday's recovery)
- Pre-Workout Fueler (last meal + planned workout → snack)
- Hydration Coach (current intake + interval prompts)
- HRV Trends
- Cycle-Aware Day Planner (for users with menstrual data)
- Step Goal Coach
- Walking Heart Rate Average Tracker
- Body Composition Tracker

### Pack 3 · Productivity (13) — calendar / reminders / Focus / Shortcuts
- Meeting Prep (next meeting → attendees + topic context)
- Weekly Planner (Sunday review of next week)
- Focus Block Finder (when's the next free 90 minutes?)
- Reminder Triage (urgent vs. important sort)
- Daily Standup Writeup
- Calendar Conflict Resolver
- Weekly Time Audit
- Project Status Brief
- **Focus-Aware Daily Brief** — checks current focus state via `focus.current`, filters the brief (Work focus → work events only; Personal focus → personal items only)
- **Pre-Meeting Focus Switch** — reads next event, suggests switching to Work focus 5 min before (via `focus.suggestSwitch`)
- **End-of-Day Focus Switch** — at user-defined time, suggests Personal focus + summarizes incomplete reminders
- **Shortcut Orchestrator** — chains user-defined iOS Shortcuts in sequence with conditional logic between steps (via `shortcuts.runShortcut`)
- **Sleep Wind-Down** — reads tomorrow's first event, schedules bedtime reminder, suggests Sleep focus 1 hour before bed

### Pack 4 · Knowledge Work (8) — power users + students
- Long-Form Summarizer (paste article → key points)
- Research Synthesizer (multiple sources → common threads)
- Document Q&A (pick a PDF via Files, ask)
- Email-to-Task (paste email → action items added to Reminders)
- Quiz Generator (topic → multiple choice)
- Flashcard Maker (topic → spaced-rep cards)
- Reading Assistant (vocab + comprehension Qs)
- Citation Formatter

### Pack 5 · Family (6) — different demographic, broad appeal
- Family Meal Planner (this week's events + preferences → menu)
- Grocery List from Menu
- Kids' Activity Suggester (age + weather + interest)
- Bedtime Story Generator
- School Project Starter
- Chore + Allowance Tracker

### Pack 6 · Developer (8) — opt-in via Developer mode
- Git Commit Message Formatter
- Code Reviewer (paste diff)
- Regex Builder
- JSON-to-Swift Struct
- Curl-to-Fetch Converter
- API Request Prepper
- Code Commenter
- README Drafter

### Pack 7 · Creative (8) — broad appeal, screenshot-worthy
- Story Starter (genre + character → opening)
- Gift Idea Generator (relationship + interests + budget)
- Naming Consultant (brand / product / character names)
- Photo Caption Writer
- Playlist Brief (mood + activity → search terms)
- Color Palette from Vibe
- Outfit Suggester (occasion + weather)
- Public Speaking Outliner

### Pack 8 · Grocery + Pantry (8) — mass-market appeal across personas
Leverages Reminders write + clipboard + storage-backed JS plugins. Showcases the "structured local data, model-readable" pattern that Avyra uniquely owns.

- **Pantry Tracker** (storage-backed JS plugin) — list, add, remove items with expiry dates
- **Recipe to Pantry Check** — paste recipe → checks pantry → shows shopping delta
- **Weekly Menu → Grocery List** — meal plan → ingredient list added to a Reminders "Groceries" list
- **Restock Suggester** — pantry items running low (count below threshold) → suggested adds
- **Receipt to Pantry** — paste receipt text → categorize items → add to pantry inventory
- **Budget Tracker** — storage-backed running monthly grocery spend with weekly burn rate alerts
- **Recurring Items** — items you buy every week → auto-add to grocery list on a schedule (Shortcuts automation)
- **Diet-Aware Suggester** — pantry + dietary tags (vegetarian, gluten-free, kid-friendly) → meal ideas tonight

**Total: 68 prebuilt workflows across 8 packs.** Ship a quality bar across all 68 before launching any. Mediocre workflows undermine the catalogue's credibility.

## 5. JS plugin tools — ~15 atomic helpers

Different from workflows. **Tools are atomic functions the model calls; users don't run them directly.** Universal utility, low cost, hugely useful as model affordances. All ship pre-installed but individually disable-able in Settings → Tools.

- **CSV/TSV parser** — paste tabular text → structured
- **Date math** — "what's 90 days from today"
- **Unit converter** — anything to anything
- **Timezone math** — "what's 3pm EST in JST"
- **Color palette generator** — hex code → palette
- **Random picker** — from a list, pick N
- **Diff** — compare two strings
- **Markdown table builder**
- **JSON-to-schema generator**
- **URL encoder / decoder**
- **Base64 encoder / decoder**
- **UUID generator**
- **Hash calculator** (SHA, MD5)
- **QR code generator** (text → SVG)
- **Lorem ipsum generator**

Each ships as a `.avyra-tool` bundle in `Apps/AvyraApp/Avyra/Resources/SeedTools/`. On first launch the JSToolProvider auto-installs them into the user's plugin directory if not present.

## 6. Templates — the path from consumer to power user

Prebuilt workflows answer **"what can this do for me?"** Templates answer **"how do I extend this for myself?"** A user who never touches a template still wins, but the moment they want to build something new, templates remove the blank-canvas barrier.

### 6.1 Unified Remix flow

Every prebuilt workflow's detail view has a **Remix** button. Tap → duplicate into the user's library as an editable copy with `parentWorkflowID` reference → push editor. The user's modifications don't touch the original. **The Remix flow IS the template flow for prebuilt content** — no separate UI needed.

Supporting affordances:

- **"My remixes"** section in the workflow library lists every workflow the user has remixed, grouped by source workflow. Discoverable signal that the catalogue is editable.
- **"Show original"** action on a remixed workflow opens a side-by-side diff against the source (same diff renderer the workflow editor uses for autosave). Reassures users that they can restore.
- **"Restore to original"** destructive action resets the remix to its source — useful when an experiment didn't work.
- **Source tracking on workflow run events** — when a remix runs, the run history shows "Remix of: Daily Health Brief" so users can correlate output quality with prompt edits.

### 6.2 Workflow skeleton templates (~10)

For users starting from genuinely nothing. Surface in the "New workflow" sheet alongside "Blank workflow."

| Template | Pre-wired shape | Teaches |
|---|---|---|
| Empty linear | LLM → Output | Cheapest start |
| Capability → LLM → Output | One placeholder cap step, LLM interpolating, Output | Binding interpolation |
| Health-driven | `health.recentSteps` → LLM → Output | Health-pack starter |
| Calendar-driven | `calendar.eventsToday` → LLM → Output | Productivity starter |
| Document Q&A | `files.readPDF` → LLM → Output | Knowledge-work starter |
| Branched | Cap → Branch → LLM(true) + LLM(false) → Output | Conditional flow |
| Loop over list | Cap returning array → Loop with body LLM → Output | Loops |
| MCP-powered | MCP tool → LLM → Output | MCP integration |
| Multi-stage LLM | LLM → Transform → LLM → Output | Chaining + transforms |
| Siri-triggered | Pre-set with `.shortcuts` trigger + named slot | AppIntent wiring |

### 6.3 JS plugin templates (~10)

Surface in `JSPluginAuthoringScreen`'s "New plugin" sheet. Each is 30–80 lines of well-commented JavaScript demonstrating one pattern. The library of templates implicitly documents the JS plugin API.

- **Hello World** — manifest + `call(input)` minimum
- **HTTP Fetcher** — `fetch(url) → json` via `http` capability
- **JSON Transformer** — pure reshape, no capabilities
- **String Parser** — regex extraction
- **Date Helper** — today + offset math
- **Multi-step Tool** — fetch → parse → return composition
- **Storage-backed Tool** — read/write per-plugin UserDefaults via `storage`
- **Clipboard Reader** — read pasteboard → process via `clipboard`
- **Share Sheet Caller** — construct text → trigger share via `share`
- **Notification Scheduler** — schedule local notification via `notifications` (once shipped)

### 6.4 Prompt snippets (~20)

For LLM step prompt fields. Snippet picker UI sits next to the existing "Available bindings" chip rail in `VariablePickerField`. Tapping a snippet inserts its body at the cursor; user fills in `{{bindings}}`.

Categories + examples:

- **Extraction** — "Extract entities (names, dates, places) from: `{{text}}`"
- **Summarize** — "Summarize in N bullets: `{{text}}`"
- **Translate** — "Translate to `{{language}}`: `{{text}}`"
- **Classify** — "Classify into one of {a, b, c}: `{{text}}`"
- **Reformat** — "Reformat as `{{format}}`: `{{text}}`"
- **Tone shift** — sub-snippets for formal, casual, friendly, concise
- **Q&A from context** — "Answer based on context: `{{context}}` Q: `{{question}}`"
- **Structured output** — JSON schema scaffolding
- **Generate from constraints** — "Generate a `{{thing}}` matching constraints: `{{constraints}}`"
- **Reason step-by-step** — Chain-of-thought scaffolding
- **Compare two** — "Compare `{{a}}` and `{{b}}` on `{{dimension}}`"

## 7. Capability gaps — what we need to ship first

Many of the strongest catalogue workflows require **write** access not currently exposed. Today's capabilities are read-only. To unlock the catalogue, eight small additions:

| Gap | Unlocks | Effort | Plist key |
|---|---|---|---|
| **Calendar write** (create event) | Focus Block Finder, Email-to-Task, Family Meal Planner | Small — EventKit `save(event:)` | `NSCalendarsFullAccessUsageDescription` |
| **Reminders write** (create reminder) | Email-to-Task, Triage, Hydration Coach, Bill Tracker, Weekly Menu → Grocery List | Small — same | `NSRemindersFullAccessUsageDescription` |
| **Clipboard read/write** | Tone Adjuster, Email Drafter, all "paste X" workflows, Receipt to Pantry | Trivial — `UIPasteboard` | none |
| **Share-sheet write** (open share sheet with text) | Email Drafter final step, LinkedIn post writer | Trivial — `UIActivityViewController` | none |
| **Notifications write** (schedule local) | Bill Tracker, Hydration Coach, Sleep Wind-Down, Bedtime suggester | Small — `UNUserNotificationCenter` | none |
| **HTTP tool as first-class capability** | Weather, currency, any net-aware workflow | Trivial — surface in capability picker | none |
| **Focus state read + suggest** | Focus-Aware Daily Brief, Pre-Meeting Focus Switch, End-of-Day Focus Switch, Sleep Wind-Down, DND respecter | Small — `INFocusStatusCenter` for read; system focus picker for suggest (Apple gates programmatic *write* to focus, the picker-suggestion path is the supported affordance) | `NSFocusStatusUsageDescription` |
| **Shortcuts invoke** (`shortcuts.runShortcut(named:)`) | Shortcut Orchestrator, Recurring Items, any meta-workflow that chains existing user Shortcuts | Small — `x-callback-url` to Shortcuts app + URL response handling | none |

All eight are small. None require new SPM deps. Each one expands the workflow-step surface AND the JS plugin capability set (so plugin tools can also use them). Total ~1 week.

### 7.1 Storage-backed JS plugin capability (already exists, surfaces here)

The Grocery + Pantry pack leans on `storage` (per-plugin sandboxed UserDefaults suite, already part of the JS plugin runtime). No new capability work — but the pack is the canonical demo of "structured user data the model can read and write" without leaving the device.

## 8. Architecture — `SeedContent`

One unified mechanism delivers prebuilt workflows, plugin tools, skeleton templates, and prompt snippets.

```swift
// Sources/WorkflowKit/Seed/SeedContent.swift
public enum SeedContent: Sendable {
    case workflow(Workflow, category: SeedCategory)
    case skeletonTemplate(Workflow, name: String, summary: String, category: SeedCategory)
    case jsPluginTool(bundleData: Data)
    case jsPluginTemplate(bundleData: Data, name: String, summary: String)
    case promptSnippet(name: String, body: String, category: SnippetCategory)
}

public enum SeedCategory: String, Sendable, CaseIterable {
    case dailyEssentials, health, productivity, knowledge, family, developer, creative
}

public protocol SeedContentSource: Sendable {
    var contents: [SeedContent] { get }
}
```

Each pack implements `SeedContentSource`. The app target wires every source into a `SeedInstaller` that runs once at first launch (idempotent — checks against the workflow / plugin stores). The user can re-seed any pack via Settings → Catalogue → "Restore defaults."

```swift
// Apps/AvyraApp/Avyra/Catalogue/SeedInstaller.swift
@MainActor
final class SeedInstaller {
    init(
        workflowStore: WorkflowStore,
        jsToolProvider: JSToolProvider,
        snippetStore: SnippetStore
    )
    func installIfNeeded(sources: [SeedContentSource]) async
    func restoreDefaults(sources: [SeedContentSource]) async
}
```

Each prebuilt workflow carries a `category: SeedCategory` so the Workflow Gallery groups them visually.

### 8.1 Workflow Gallery UI

New `WorkflowGalleryScreen` at the root of Settings → Workflows (or above the existing list). Sections:

- **Recommended for you** — sorted by which permissions the user has already granted (HealthKit → Health pack first; Calendar → Productivity pack first).
- **Categories** — one section per `SeedCategory` with horizontal scroll cards.
- **My workflows** — user-authored / remixed at the bottom.

Each card: icon + name + 1-line summary + permissions chips (HealthKit / Calendar / etc.) + Run button + ⋯ menu (Remix, View source, Hide).

Detail view per workflow:
- Step-by-step preview (read-only canvas)
- Permissions required
- **Run** button (large, primary)
- **Remix** button (secondary)
- "What it does" description
- "How to invoke" hints (manual / Siri phrase / URL)

### 8.2 Snippet picker UI

Sits below the existing "Available bindings" chip rail in `VariablePickerField`. Compact chip rail labeled "Snippets" → tap to expand a sheet → categorized list (Extraction / Summarize / Translate / etc.) → tap a snippet → inserts at cursor.

Stored in app bundle as a JSON file (`SeedSnippets.json`) loaded once at startup. Users can author their own (Phase 3+) but that's not P0.

### 8.3 Plugin template picker

`JSPluginAuthoringScreen` gets a new "Start from a template" sheet on entry when there's no draft. Lists the ~10 templates; tap → pre-fills the editor with the template's manifest + source.

## 9. Marketing surface

The catalogue is a marketing engine if we expose it right.

### 9.1 Sharable workflows

Each prebuilt + user-authored workflow has a **shareable export**: `.avyra-workflow` JSON, opened via a custom URL scheme (`avyra://import?...`) or via the Files app. **Sharing flow**: tap Share on a workflow → standard share sheet → recipient taps the link → opens App Store / Avyra with the workflow pre-imported.

### 9.2 Screenshot bait

Health Brief screenshots are visually rich and personal. The Run sheet's final-output card should be designed for **screenshotting** — clean typography, the Avyra wordmark in a corner, model name watermark. Encourage sharing organically.

### 9.3 App Store positioning

Three keyword/category opportunities — list under all three:

- **Health & Fitness** — "Privacy-first AI for your Health data"
- **Productivity** — "AI workflows that act on your Calendar + Reminders"
- **Utilities** — "Build your own AI workflows. On-device."

### 9.4 Landing page comparison tables

Match users to their existing app:

- **vs. ChatGPT** — privacy ✓ vs ✗, health data ✓ vs ✗, free ✓ vs $20/mo, workflows ✓ vs ✗
- **vs. Apple Shortcuts** — LLM ✓ vs ✗, prebuilt content ✓ vs configure-it-yourself, conversational ✓ vs scripted

### 9.5 Persona-targeted launch waves

Don't blast "AI assistant" generically. Target each persona's communities specifically:

- **Health/fitness obsessives** — Whoop, Strava, Oura subreddits + Discords. Lead with HealthKit story.
- **Apple ecosystem power users** — MacStories, Reddit /r/shortcuts. Lead with Workflow + Siri integration.
- **Privacy advocates** — DuckDuckGo, Signal user lists. Lead with "no servers" story.
- **Productivity nerds** — Things, OmniFocus, Notion communities. Lead with Calendar/Reminders integration.

## 10. Implementation phases

Sequenced so each phase ships independent value. None require unfinished items from the skills design doc.

### Phase 1 — Capability gaps (~1 week)
- Calendar write (create event with title, start, duration)
- Reminders write (create reminder with title, due date, list)
- Clipboard capability (read + write)
- Share-sheet capability (open share sheet with text)
- Notifications capability (schedule local notification)
- HTTP tool surfaced in capability picker
- Focus state read + system-picker suggest
- Shortcuts invoke (by name, via `x-callback-url`)
- Tests per capability + Info.plist usage strings where required

### Phase 2 — Seed infrastructure (3–4 days)
- `SeedContent` + `SeedContentSource` + `SeedInstaller` in WorkflowKit
- Each pack as a `SeedContentSource` in the app target
- Workflow Gallery UI (`WorkflowGalleryScreen`) replacing the bare workflow list
- Settings → Catalogue → "Restore defaults" surface
- Remix button on workflow detail view (creates editable copy in user's library)

### Phase 3 — Pack 1 + Pack 2 + Pack 8 (~2.5 weeks) → v1.1 launch
The 30 highest-impact workflows: Daily Essentials (10) + Health (12) + Grocery + Pantry (8). Each gets:
- JSON workflow definition
- Tuned prompt template (validated against Apple Intelligence + Qwen 1.5B + Qwen 4B)
- Permission chip metadata
- 1-line marketing summary
- Test data + manual QA across all three model classes

Also lands in this phase:
- Snippet picker UI + 20 snippets shipped as JSON
- Plugin tools (15) shipped as bundled `.avyra-tool` assets, auto-installed on first launch

Pack 8 (Grocery + Pantry) lands in v1.1 because it (a) showcases the storage-backed plugin pattern that nothing else demonstrates, (b) has mass-market appeal across personas (not just families), (c) is the canonical demo of "your data, local, structured, model-readable."

### Phase 4 — Packs 3–7 (~2 weeks)
- Productivity (13, includes Focus + Shortcuts workflows), Knowledge (8), Family (6), Creative (8), Developer (8) = ~43 workflows
- Plugin templates (10) shipped + surfaced in authoring screen
- Workflow skeleton templates (10) surfaced in "New workflow" sheet

### Phase 5 — Marketing + sharing surface (3–4 days)
- `.avyra-workflow` export format + custom URL scheme handler
- Share sheet integration
- Run sheet output card redesign for screenshotting
- Landing page assets

**Total: ~6 weeks** from start to launch-ready catalogue with all 68 workflows, 15 plugin tools, 20 snippets, 10 skeleton templates, 10 plugin templates, and marketing surface.

v1.1 milestone at end of Phase 3 (~4 weeks in) — 30 workflows shipped, app meaningfully transformed. Phases 4–5 deliver the rest as v1.2 / v1.3 incremental updates.

## 11. Quality bar

Each prebuilt workflow ships only after:

- [ ] Prompt tuned on Apple Intelligence + Qwen 2.5 1.5B (the floor) + Qwen 3.5 4B (the middle)
- [ ] Runs successfully on at least 5 representative inputs
- [ ] Permissions explicitly enumerated in metadata
- [ ] 1-line summary < 80 chars (Workflow Gallery card constraint)
- [ ] No external network requirement unless the user explicitly enables an HTTP-tool step
- [ ] Idempotent (running twice produces equivalent output)
- [ ] Background-context safe (or marked "interactive-only" in metadata if it requires biometrics / share sheet / etc.)

A workflow that doesn't clear the bar gets postponed to the next pack release. Better to ship 50 great workflows than 60 mediocre ones.

## 12. Open questions

1. **First-launch friction vs catalogue value** — should the gallery be the literal first screen (before chat), or should chat remain the primary surface with gallery one tap away? **Recommendation**: gallery as a featured prompt in the Welcome message on first chat; persistent entry from Settings + a "Templates" button in the chat composer.
2. **Workflow versioning** — when we ship Pack 2 v1.1 with a tuned prompt, do we overwrite user-installed copies or treat user-installed as forks? **Recommendation**: user-installed copies are forks; we never overwrite. The Catalogue tab shows "Update available" badges with diff preview.
3. **Network-dependent workflows in background contexts** — Recipe from Ingredients on Hand uses no network; Weather-aware workflows do. Background Shortcuts can't reach network. **Recommendation**: tag each workflow with `backgroundSafe: Bool`; the AppIntent surface filters appropriately. Already partial — extend to all seeded workflows.
4. **Server LLM provider as catalogue default** — if a user has OpenAI configured, should catalogue workflows route through it by default? **Recommendation**: no. Catalogue workflows pin to Apple Intelligence by default to keep behaviour consistent across users; the user can Remix and switch the model per step.
5. **Prompt-snippet localisation** — single-language at launch (English). Localization is a per-snippet body translation pass. **Recommendation**: ship English at v1; structure snippet storage so a `locale` lookup is a one-line change later.
6. **Plugin tool sandboxing** — the 15 first-party plugin tools are written by us, but they still run in the JS plugin sandbox. Should first-party tools have any expanded permission surface? **Recommendation**: no — same sandbox as user plugins. Sets the right precedent and proves the sandbox is sufficient for "real" tools.
7. **Template attribution** — when a user Remixes "Daily Health Brief," does the copy show "Based on: Daily Health Brief"? **Recommendation**: yes. Stored as `parentWorkflowID` field. Useful for "Show original" affordance and for telemetry on which templates seed the most user-authored workflows.

## 13. Out of scope (deliberately)

- **Workflow marketplace** — community-uploaded workflows with ratings. Big product surface. Could land as Phase 7+ once the catalogue + sharing format prove viable.
- **Workflow analytics** — track which workflows run most, which fail most. Could land alongside the existing tracing recorder.
- **Per-user prompt tuning / RLHF** — let the user mark output "good / bad" and improve prompts over time. Future product surface.
- **Cross-device sync of remixed workflows** — already covered via iCloud Backup (per the legal/privacy docs). Real-time sync is a Phase 7+ product feature.
- **AI-generated workflows** — model authors a workflow from a natural-language request. Compelling but quality-gating is hard. Future.

## 14. Decision summary

- The catalogue is the bridge between Avyra's technical moat (on-device + system data access) and mass-market adoption.
- **68 prebuilt workflows** across 8 packs, each tuned against the bottom-end model in the catalogue.
- **15 JS plugin tools** auto-installed and disable-able.
- **10 skeleton templates + 10 plugin templates + 20 prompt snippets** as the bridge from consumer to power user.
- **8 capability gaps** (Calendar write, Reminders write, Clipboard, Share, Notifications, HTTP first-class, Focus state, Shortcuts invoke) ship in Phase 1 — prerequisite for many workflows.
- **`SeedContent`** in WorkflowKit unifies all four content types into one install / re-seed mechanism.
- **Workflow Gallery UI** with Remix button does dual duty as catalogue browser AND template gallery for prebuilt content. "My remixes" + "Show original" affordances make the editability discoverable.
- **v1.1 milestone at ~4 weeks** — Daily Essentials + Health + Grocery (30 workflows). Remaining packs land as v1.2 / v1.3.
- **~6 weeks total** to ship the full catalogue.
- The Skills work (`2026-05-21-avyra-skills-design.md`) can land in parallel — different code paths, no blocking dependency.

If approved, Phase 1 (capability gaps) is the natural starting point — small, high-leverage, unblocks everything downstream.
