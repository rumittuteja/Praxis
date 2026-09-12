# Praxis

A personal AI-engineering tutor for iOS. It teaches building with Claude and
Amazon Bedrock through daily sessions: spaced-repetition review, one new
concept, an interleaved quiz, and a hands-on task that Claude grades against a
rubric.

Multiple local profiles, each with its own progress graph. Both the Anthropic
API and Amazon Bedrock are implemented, switchable in Settings.

> **This has never been compiled.** It was written in a Linux container with no
> macOS, no Xcode, and no simulator. The architecture, the curriculum, and the
> algorithms are the work; expect to fix some compile errors on first build.
> The unit tests are the fastest way to find them — see *First build* below.

---

## Requirements

- macOS with **Xcode 16 or later** (the project uses synchronized file groups,
  which Xcode 15 cannot read).
- iOS 17+ target. Runs on the simulator; a device needs a signing team.
- An **Anthropic API key**, or **AWS credentials** with Bedrock access, or both.
  Warm-up reviews work with neither.

## First build

```bash
open Praxis.xcodeproj
```

Set your signing team on the `Praxis` target if you're running on a device,
then ⌘R.

**Run the tests first** (⌘U). They cover the pure logic — spaced repetition,
SigV4, the Bedrock event-stream decoder, wire encoding, the planner, the
curriculum graph — with no network and no UI, so they will surface most
mistakes faster than launching the app.

If the project file itself is ever damaged, regenerate it:

```bash
brew install xcodegen && xcodegen generate
```

## Setup

Everything is in **Settings** inside the app. Credentials go to the Keychain
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — device-only, excluded
from iCloud Keychain and from backups) and are never written anywhere else.

**Anthropic** — paste an API key from the Console. That's the whole setup.

**Bedrock** — paste an access key ID and secret (plus a session token if you're
using temporary credentials, which you should be), pick a region, and pick a
model. Two things to check when a call fails:

1. The IAM principal needs `bedrock:InvokeModel` and
   `bedrock:InvokeModelWithResponseStream`.
2. The model must be **enabled for that specific region** in the Bedrock
   console. Enabling it in `us-east-1` does nothing for `eu-west-1`. This is the
   single most common first-day error, and it's also lesson
   `bedrock-model-access` in the curriculum.

**GitHub token** — optional. It only raises the anonymous 60-requests-per-hour
limit during documentation sync.

---

## How a session works

Each day the planner builds a session from your progress graph:

| Step | What it does | Cost |
|---|---|---|
| **Warm-up** | Retrieval practice on concepts that are due. Recall, then reveal, then self-rate. | Free — no model call |
| **Lesson** | One new concept. Worked example first, then explanation, then takeaways. | 1 call (Opus 5) |
| **Quiz** | 4–8 items interleaving the new concept with older ones. Confidence stated before each reveal. | 1 call (Haiku) + 1 if you wrote free text |
| **Task** | Hands-on work you do elsewhere and paste back, graded against a rubric shown up front. | 2 calls (Opus 5) |
| **Reflection** | Explain it in your own words. Stored, never graded. | Free |

Reviews are always scheduled before new material, so a smaller daily goal means
fewer new concepts rather than weaker retention.

### The learning design

Not decoration — each of these is load-bearing:

- **Spaced repetition (SM-2)** with two departures from the textbook algorithm.
  Progression gates on a separate *mastery* estimate rather than on repetition
  count, because passing four easy recalls is not understanding. And being
  wrong while *certain* schedules the card for tomorrow, because you have no
  internal signal telling you to review it.
- **Retrieval practice first.** Recall before re-reading, every session.
- **Interleaving.** Quizzes mix concepts so you have to notice which idea
  applies, rather than pattern-matching to whatever you just read.
- **Worked examples, then faded practice.** Task scope grows with mastery: the
  same concept yields "follow these five steps" at low mastery and "here's a
  goal and a hard constraint" at high mastery.
- **Confidence calibration.** You state confidence before each reveal. The gap
  between confidence and correctness is tracked per concept and surfaced on the
  Progress screen. Confident-and-wrong is the pattern that costs you most and
  the one you cannot detect alone.
- **Elaborative interrogation.** Lessons name a specific misconception and
  refute it, rather than only presenting the correct version.

---

## The curriculum

104 concepts across 7 tracks, hand-authored as a prerequisite graph in
`Praxis/Curriculum/Resources/curriculum.json`. At one new concept a day that's
about five months.

| Track | Concepts | Covers |
|---|---|---|
| Prompting & Context Engineering | 14 | Request anatomy → context engineering → prompting long-horizon agents |
| The Claude API | 18 | Messages API → caching, thinking, effort, structured outputs, cost |
| Tool Use & Agents | 16 | Tool definitions → the agentic loop → tool surface design, Managed Agents |
| Agentic Development | 12 | Claude Code as a harness → memory, hooks, skills, subagents, the Agent SDK |
| Evaluation & Reliability | 9 | Why evals → graders → held-out splits → hillclimbing → model migration |
| AWS & Amazon Bedrock | 23 | AWS accounts and IAM → SigV4 → InvokeModel → guardrails, knowledge bases, production architecture |
| Production AI Engineering | 12 | Key management → latency, retries, injection defense → capstone |

The graph is validated as a unit test: no cycles, no dangling prerequisites,
every concept reachable, and tiers monotonic (nothing is rated easier than its
hardest prerequisite).

The AWS track assumes **zero** prior AWS knowledge and builds to production
architecture. The Claude tracks assume you already know what tokens and context
windows are, and start above that.

### Where content comes from

There is no public "Claude tutorials API." The material lives in Anthropic's
docs, the `anthropics/courses` and `anthropic-cookbook` repositories, and AWS's
Bedrock guide. So:

1. The **syllabus** — concepts, ordering, prerequisites, objectives, key ideas,
   misconceptions — is authored and versioned in this repo.
2. **Docs sync** fetches those 49 source URLs into a local corpus, extracting
   text from HTML, Markdown, and Jupyter notebooks. ETag and Last-Modified
   revalidation makes refreshes mostly cheap 304s.
3. **Retrieval** picks the passages relevant to today's concept, within a fixed
   character budget, and those ground the generated lesson.

Lessons cite only URLs from the supplied list, so the model cannot invent a
plausible-looking documentation link.

> The source URLs were written to match each documentation site's structure at
> time of authoring. Some will drift. Failures are reported per-source in
> Settings → Sync, and a lesson with no corpus hit still generates — it just
> says so rather than bluffing.

---

## Architecture

```
Praxis/
├─ App/              Entry point, environment, SwiftData repository
├─ DesignSystem/     Claude-derived palette, components, Markdown renderer
├─ Models/           SwiftData entities + the model catalog
├─ Curriculum/       Concept graph types, store, curriculum.json
├─ Providers/        LLMProvider protocol, Anthropic, Bedrock, SigV4, event stream
├─ Learning/         SM-2, mastery model, session planner
├─ Generation/       Prompts, JSON schemas, TutorService
├─ DocsSync/         Fetching, text extraction, retrieval
└─ Features/         Profiles, Today, Lesson, Quiz, Tasks, Progress, Library, Settings
```

### The provider layer

One `LLMProvider` protocol, two implementations. Everything above it is
provider-agnostic, which is what makes the Settings toggle real rather than
cosmetic.

|  | Anthropic | Bedrock |
|---|---|---|
| Endpoint | `api.anthropic.com/v1/messages` | `bedrock-runtime.<region>.amazonaws.com/model/<id>/invoke` |
| Auth | `x-api-key` header | SigV4, service `bedrock` |
| Model ID | `claude-opus-5`, in the body | `anthropic.claude-opus-5`, in the URL path |
| Version | `anthropic-version` header | `anthropic_version` body field |
| Streaming | SSE | Binary `vnd.amazon.eventstream` frames |

The streaming difference is the interesting one: the JSON events *inside*
Bedrock's binary frames are byte-identical to the first-party SSE payloads, so
`StreamAccumulator` is shared and both providers stay thin. SigV4 signing and
the event-stream decoder are hand-written (no AWS SDK dependency) and tested
against AWS's published reference vectors.

Structured output uses **strict tools** rather than a response-format
parameter, because strict tool use is supported on both providers.

### Cost

Roughly 4–5 model calls per session. Lessons and grading run on Opus 5; quiz
generation runs on Haiku 4.5, since generating items from an already-written
lesson is mechanical work.

The stable part of every system prompt sits behind a one-hour cache breakpoint,
with per-request content after it. **Settings → Request inspector** shows every
call with tokens, cache hit rate, latency, and estimated cost. Watching your own
cache hit rate is itself part of the syllabus — if it stays at zero, something
in the prefix is changing between requests.

Cost figures use Anthropic list prices. Bedrock is billed separately by AWS at
its own rates, and the UI says so.

---

## Deliberate tradeoffs

**API keys live on the device.** For a single-user personal app with no backend,
Keychain storage is the pragmatic choice. It does not generalise: anything with
real users needs a backend proxy holding the credential, which is also where
per-user rate limiting, spend caps, and audit logging belong. This is lesson
`prod-key-management`, and the app is an explicit counterexample to its own
advice.

**Profiles are local only.** No accounts, no sync, no server. Delete the app and
the data is gone. CloudKit sync would be a contained change — the models use
`learnerID` foreign keys rather than relationships, so a sync layer wouldn't
have to untangle an object graph.

**Generated content is cached, not regenerated.** Reopening a lesson costs
nothing and shows exactly the text you read the first time.

## Known gaps

- Never compiled. Expect first-build errors.
- No app icon (the asset slot is there and empty).
- Grading quality is unvalidated. There is no eval for the tutor itself, which
  is a slightly awkward omission in an app that teaches you to build evals — the
  honest next step is a small eval set of submissions with known grades.
- Docs sync is sequential and can take a minute or two on first run.
- Bedrock model IDs assume plain identifiers. Raw ARNs as model IDs would need
  the second URI-encoding pass that SigV4 requires for non-S3 services.
