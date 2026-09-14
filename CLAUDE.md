# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Status

**This code has never been compiled.** It was authored without access to macOS or
Xcode. Before trusting any part of it, build it. Errors found and fixed by
inspection so far: enum-case associated-value defaults (illegal in Swift),
`SortDescriptor` on a `UUID` (not `Comparable`), a shared mutable
`DateFormatter`, and absolute index arithmetic on sliced `Data`. Expect more of
the same class.

## Commands

Requires **Xcode 16+** — the project uses `PBXFileSystemSynchronizedRootGroup`,
which earlier versions cannot read.

```bash
# Test (do this first — pure logic, no network or UI, fails fast)
xcodebuild test -scheme Praxis -destination 'platform=iOS Simulator,name=iPhone 16'

# Build only
xcodebuild build -scheme Praxis -destination 'platform=iOS Simulator,name=iPhone 16'

# One suite, or one test within it (Swift Testing struct name, not the @Suite display name)
xcodebuild test -scheme Praxis -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:PraxisTests/SpacedRepetitionTests
xcodebuild test -scheme Praxis -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:PraxisTests/SigV4Tests/signingKeyDerivation

# Regenerate the project file if it is ever damaged
xcodegen generate
```

Adding or deleting source files needs **no project-file edit** — synchronized
groups pick up anything under `Praxis/` and `PraxisTests/` automatically.

Language mode is **Swift 5**, set deliberately. Strict-concurrency issues in the
provider layer surface as warnings rather than errors. Moving to Swift 6 means
auditing `HTTPSupport.session`, `RequestLog`, and the `@MainActor` boundaries
first.

## Architecture

Data flows one way, and each layer is testable without the one above it:

```
curriculum.json ──> CurriculumStore ──┐
                                      ├──> SessionPlanner ──> DailyPlan
ConceptProgress ──> ReviewState ──────┘                          │
                                                                 v
DocSnapshot ──> DocsRetriever ──> RetrievedExcerpt ──> TutorService ──> LLMProvider
                                                                 │
                                    SessionCoordinator <─────────┘
                                            │
                                            v
                                       SwiftUI views
```

### Six things that require reading several files to understand

**1. The learning engine is pure, and deliberately not SwiftData.**
`SpacedRepetition`, `SessionPlanner` and `MasteryModel` operate on `ReviewState`
values, never on model objects. `ConceptProgress` bridges via `.reviewState` and
`.apply(_:)` in `SpacedRepetition.swift`. Keep new scheduling logic on the value
side — that is why it is testable, and why a scheduling bug cannot leave a
half-written managed object behind.

**2. Persistence uses foreign keys, not SwiftData relationships.**
Every child record carries a `learnerID: UUID`. `#Predicate` traversal across
relationships has been unreliable, so this trades an explicit cascade for
predictable queries. **The cascade is manual** — adding a new per-learner model
means adding a matching `context.delete(model:where:)` line to
`LearningRepository.deleteLearner`, or you leak orphans that silently count
toward the next profile's statistics.

**3. One `StreamAccumulator` serves both providers.**
The JSON events inside Bedrock's binary `vnd.amazon.eventstream` frames are
byte-identical to first-party SSE payloads. `AnthropicProvider` unwraps SSE
lines, `BedrockProvider` unwraps binary frames plus a base64 `bytes` field, and
both then feed the same accumulator. Fix stream-assembly bugs there once, not
twice.

**4. `MessagesRequest.bedrockStyle` flips the encoding.**
Set it and `encode(to:)` omits `model` (Bedrock takes it in the URL path) and
emits `anthropic_version: "bedrock-2023-05-31"` instead. Everything else about
the request shape is shared.

**5. Structured output goes through strict tools, not `output_config.format`.**
`TutorTools` defines one emit-tool per generation kind with `strict: true`,
`additionalProperties: false`, and every property required. This is for provider
portability — strict tool use works on Bedrock; newer response-format parameters
do not. `tool_choice` is `.auto` plus an explicit instruction naming the tool,
because forced tool choice 400s on some current models.

**6. `Prompts.tutorCore` must stay byte-identical across every request.**
It sits first in the system array behind a one-hour cache breakpoint, with all
per-request content after it. **Never interpolate anything into it.** A single
varying byte drops the cache hit rate to zero, silently — no error, just a
larger bill. The request inspector (`RequestInspectorView`) exists partly so this
is observable.

### Model selection

`TutorService` uses two models on purpose. Lessons, task generation and grading
run on the learner's chosen model (Opus 5 by default) with
`thinking: .adaptiveVisible` and `effort: "high"` — the reasoning summary streams
to the UI as progress. Quiz generation and short-answer grading run on the
utility model (Haiku 4.5) with **`thinking: nil`**: Haiku does not accept
adaptive thinking, and the work is mechanical.

### Grading reconciliation

`TutorService.reconcileOverall` recomputes the headline score from the weighted
per-criterion breakdown, discarding the model's own `overallScore` when they
disagree. The breakdown is what the learner sees, so a headline contradicting its
own justification is worse than a slightly different number.

## The curriculum

`Praxis/Curriculum/Resources/curriculum.json` is the source of truth: 104
concepts, 7 tracks, 49 source URLs. Hand-editable.

`CurriculumTests` enforces the graph invariants, so run it after any edit:

- no duplicate ids, no dangling prerequisites, no cycles
- every concept reachable from a prerequisite-free root
- **tiers monotonic** — no concept may be rated easier than its hardest
  prerequisite (this one catches real authoring mistakes)
- every concept has objectives, key ideas, misconceptions, sources, practice kinds
- every source URL parses and is https

Adding a concept means adding the JSON object and running that suite. Concept
`id`s also act as retrieval keywords (`DocsRetriever.terms`) and as GitHub path
match keys (`DocsSyncService.keywords`), so descriptive hyphenated ids like
`bedrock-invoke-model` work materially better than opaque ones.

## Theming

All color and type resolves through `DesignSystem/Theme.swift`. There are no
color hex literals and no raw `.system(size:)` calls anywhere else in the app,
and it is worth keeping it that way — a re-skin should stay a one-file edit.

- `Palette.accentHex` is the single source of truth for the accent.
  `AccentColor` in the asset catalog carries the same value because system
  chrome reads the asset rather than our code, and `ThemeTests` asserts they
  match in both appearances. Change one, change both.
- `Palette.onAccent` is **derived** from the accent's WCAG relative luminance,
  not hardcoded, so a pale accent cannot produce white-on-white. The 0.5
  threshold deliberately preserves white-on-clay rather than maximising
  contrast; see the comment on the property before changing it.
- `Typeface` is for text, `Glyph` is for SF Symbols and emoji. They are separate
  so that scaling text later does not resize icons.
- Sizes are **not** Dynamic Type aware — see Known gaps.

## Conventions worth preserving

- **Lessons cite only supplied URLs.** `citedSourceURLs` is validated against the
  concept's own `sources` in `SessionCoordinator.loadLesson`, so the model cannot
  invent a plausible documentation link. Keep that filter.
- **Warm-up makes no API call.** Retrieval practice is the highest-value step and
  must never be blocked by a rate limit, a missing key, or no signal.
- **Pure statics called from tests are `nonisolated`** (e.g.
  `SessionCoordinator.localScore`), since `@MainActor` statics are unreachable
  from a nonisolated test.
- **Credentials only ever touch `CredentialStore`.** Nothing else reads or writes
  the Keychain, and no code path logs or displays a saved secret.

## Known gaps

**No eval for the tutor's own grading quality**, in an app whose curriculum
teaches you to build evals. A small set of submissions with known grades run
against the grading prompt is the first thing worth adding.

**No Dynamic Type support.** Every font is a fixed point size, so the app
ignores the user's text-size setting entirely. Fixing it properly means either
mapping `Typeface` onto semantic text styles (`.body`, `.caption`) and accepting
their sizes, or driving sizes through `@ScaledMetric` per view — and then
checking the layout survives at accessibility sizes. That is a design pass, not
a mechanical change, and it cannot be validated without running the app. The
10pt `Typeface.nano` role is below Apple's 11pt legibility guidance and is the
first thing to revisit.
