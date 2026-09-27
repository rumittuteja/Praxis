# Praxis

**A personal AI-engineering tutor for iOS.** It teaches you to build with Claude
and Amazon Bedrock — not by handing you documentation, but by running a short
structured lesson every day, testing whether it stuck, and giving you real work
to do that gets graded against a rubric.

---

## Table of contents

- [What this is, and why](#what-this-is-and-why)
- [Project status](#project-status)
- [Requirements](#requirements)
- [Part 1 — Getting it running](#part-1--getting-it-running)
- [Part 2 — First-time setup inside the app](#part-2--first-time-setup-inside-the-app)
- [Part 3 — Using it day to day](#part-3--using-it-day-to-day)
- [Part 4 — The other screens](#part-4--the-other-screens)
- [The curriculum](#the-curriculum)
- [How the learning design works](#how-the-learning-design-works)
- [Where content comes from](#where-content-comes-from)
- [What it costs to run](#what-it-costs-to-run)
- [Multiple profiles](#multiple-profiles)
- [Privacy and data](#privacy-and-data)
- [Keeping the curriculum current](#keeping-the-curriculum-current)
- [Architecture](#architecture)
- [Theming](#theming)
- [Localization](#localization)
- [Troubleshooting](#troubleshooting)
- [Known gaps](#known-gaps)

---

## What this is, and why

The material for learning AI engineering exists and is mostly free. Anthropic's
documentation is good, the cookbook is full of working examples, AWS documents
Bedrock exhaustively. The problem is not access. The problem is that reading
documentation produces a strong feeling of understanding and very little actual
retention, and there is no moment where anyone tells you that the thing you
believe about prompt caching is wrong.

Praxis is built around that gap. It does four things that reading does not:

**It schedules.** Concepts come back on a spaced-repetition schedule tuned to
how well you actually did on them, so material resurfaces just as it is about
to fade rather than when you happen to think of it.

**It tests before it teaches.** Every session opens with recall on things you
have already seen, before any new material. Retrieving something from memory is
what strengthens it; re-reading it mostly strengthens your confidence.

**It makes you do the work.** Each session ends with a hands-on task — write
this prompt, build this thing in Claude Code, run this against Bedrock and
report what happened — which you submit and which Claude grades against a
rubric shown to you before you start.

**It tells you when you are wrong while feeling right.** You state your
confidence before each answer is revealed. The gap between how sure you were
and how right you were is tracked per concept and surfaced. Being confidently
wrong is the failure mode that costs the most and the one you cannot detect on
your own.

The curriculum runs from prompting fundamentals through the Claude API, tool use
and agents, Claude Code, evaluation, and a full ground-up track on AWS and
Amazon Bedrock, ending in production architecture. It assumes you already know
what tokens and context windows are. It assumes nothing whatsoever about AWS.

---

## Project status

**This code has never been compiled.** It was written in a Linux container with
no macOS, no Xcode, and no simulator. The architecture, the curriculum, the
algorithms and the tests are all real work, but the first build will surface
compile errors that could not be caught without a compiler.

Several classes of error were found and fixed by inspection — a default value on
an enum case associated value (which Swift forbids), sorting SwiftData by a
`UUID` (which is not `Comparable`), a shared mutable `DateFormatter`, and
absolute index arithmetic on `Data` that is unsafe after slicing. Inspection has
limits, so expect more.

The 109 unit tests are the fastest path to a clean build. They cover the pure
logic with no network and no UI, so they compile and fail quickly.

---

## Requirements

| | |
|---|---|
| **Xcode** | 16 or later — required. The project uses synchronized file groups, which Xcode 15 cannot read. |
| **iOS** | 17.0 or later. Builds for iPhone and iPad. |
| **Credentials** | An Anthropic API key, or AWS credentials with Bedrock access, or both. Warm-up reviews work with neither. |
| **Apple Developer account** | Only if you want to run on a physical device. The simulator needs nothing. |

---

## Part 1 — Getting it running

### 1. Clone the repository

```bash
git clone https://github.com/rumittuteja/Praxis.git
cd Praxis
```

### 2. Open the project

```bash
open Praxis.xcodeproj
```

If Xcode opens to an apparently empty file list, you are on Xcode 15 or earlier.
Synchronized file groups are an Xcode 16 feature and older versions cannot read
them. Upgrade, or regenerate the project file with XcodeGen:

```bash
brew install xcodegen && xcodegen generate
```

### 3. Run the tests first

Press **⌘U**.

Do this before trying to run the app. The test suite exercises the spaced
repetition algorithm, AWS SigV4 signing (against AWS's own published reference
vectors), the Bedrock binary event-stream decoder, the Messages API wire
encoding, the session planner, and the integrity of the curriculum graph. None
of it touches the network or the UI, so it compiles fast and fails informatively.

If the build fails, the first error is almost always the only real one — Swift
generates a lot of cascading noise after an initial failure. Fix from the top.

### 4. Set a signing team, if using a device

Select the **Praxis** target → **Signing & Capabilities** → choose your team.
Skip this entirely if you are running in the simulator.

### 5. Run

Press **⌘R**. The app opens on the profile picker, because no profile exists yet.

---

## Part 2 — First-time setup inside the app

### Step 1 — Create your profile

Tap **Add a profile** and fill in four things:

**Name.** Used in greetings and to label the profile.

**Avatar.** Pick an emoji. Cosmetic, but it makes switching between profiles
legible at a glance.

**Daily goal.** Between 5 and 90 minutes, defaulting to 20. This is a real
budget, not a suggestion — the session planner fits work into it. Reviews are
always scheduled first, so a smaller goal means fewer new concepts rather than
weaker retention. Twenty minutes is a sustainable default; if you find yourself
skipping days, lower it rather than pushing through.

**What you already know.** This one matters more than it looks. The text you
write here is injected into every generation prompt, so it directly controls the
altitude lessons are pitched at. Be specific at both ends — what you are fluent
in, and what you have genuinely never touched.

> A useful example: *"Ten years backend engineering, mostly Go and Python. Use
> Claude Code daily and I'm comfortable with tokens, context windows and basic
> prompting. Never written an agent loop. Complete beginner on AWS — no account,
> don't know what IAM is."*

That gets you lessons that skip the basics you have and build AWS from zero,
which is exactly the split most material gets wrong.

### Step 2 — Add credentials

Go to the **Settings** tab. Everything below is stored in the iOS Keychain with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which means device-only,
excluded from iCloud Keychain and excluded from device backups. Nothing is
written anywhere else, and the app never displays a saved secret back to you.

You need at least one provider. Adding both lets you compare them, which is
itself part of the syllabus.

#### Option A — Anthropic API (simplest)

1. Get an API key from the Anthropic Console.
2. Paste it into the **Anthropic API** section.
3. Tap **Save key**.
4. Optionally change the model. Opus 5 is the default and the right choice for
   lessons and grading.

That is the entire setup.

#### Option B — Amazon Bedrock (more setup, more to learn)

Bedrock needs three things lined up, and people usually miss the third.

1. **Create an IAM identity with Bedrock permissions.** The principal needs
   `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream`.

2. **Enable model access for your region.** In the AWS console, go to Bedrock →
   Model access, and request access to the Anthropic models you want. This is
   per-model *and* per-region.

3. **Match the region in the app to the region you enabled.** Enabling a model
   in `us-east-1` does nothing for `eu-west-1`. This is the single most common
   first-day Bedrock error, and it is also lesson `bedrock-model-access` in the
   curriculum — you will hit it before you are taught it.

Then in Settings → **Amazon Bedrock**:

1. Paste your access key ID and secret access key.
2. Paste a session token as well, if you are using temporary credentials.
3. Pick the region you enabled models in.
4. Pick a model. Note the `anthropic.` prefix — Bedrock model IDs are not the
   same strings as first-party ones.
5. Tap **Save credentials**.

> **On credential choice:** prefer temporary credentials with a session token
> over a long-lived access key. A long-lived key is a password that never
> expires, and this app stores it on a phone. This tradeoff is lesson
> `aws-credentials`, and the app is deliberately an example of the compromise
> rather than the ideal.

#### Optional — GitHub token

In the **Source material** section. It only raises GitHub's anonymous rate limit
of 60 requests per hour during documentation sync. The app works fine without
one; you may just see a few sync failures on the repository-backed sources.

### Step 3 — Sync the documentation

Still in Settings, under **Source material**, tap **Sync documentation now**.

This fetches 49 source URLs — Anthropic's docs, the `anthropics/courses` and
`anthropic-cookbook` repositories, and AWS's Bedrock guide — into a local corpus,
extracting readable text from HTML pages, Markdown files and Jupyter notebooks.
Lessons are then grounded in retrieved passages from that corpus rather than in
the model's recollection of documentation.

The first sync is sequential and takes a minute or two. Later syncs are mostly
cheap 304 Not Modified responses, because the app stores ETag and Last-Modified
validators and revalidates rather than refetching.

Some sources will fail. Documentation sites restructure, and the URLs were
written against their structure at authoring time. Failures are listed
per-source in the sync report. A concept whose sources all failed still
generates a lesson — the tutor is instructed to say plainly what it is unsure of
rather than bluff.

You can skip this step. Lessons will be less well grounded, and citations will
be empty.

### Step 4 — Start

Go to the **Today** tab. Your first session is waiting.

---

## Part 3 — Using it day to day

Open the app once a day. The **Today** screen shows a greeting, your streak, an
estimate of how long the session will take, and a progress bar across the steps.
Below that is a list of steps, with the next one marked. Tap a step to enter it.

A day's session is built fresh each morning from your progress graph and stays
fixed for the day, so it will not reshuffle underneath you. Not every step
appears every day: a day with nothing due has no warm-up, and a day where your
review backlog is large may have no new concept at all.

### Step 1 — Warm-up (free, no model call)

You are shown a concept you have studied before and asked to recall it —
"Without looking: what is prompt caching, and when does it matter?" — with no
answer visible.

**Actually try to answer.** Out loud, or in your head, or on paper. The effort of
retrieval is the entire mechanism; skipping straight to the reveal converts a
high-value exercise into low-value re-reading.

Then tap **Reveal** to see the key points, and rate how it went:

| Rating | Means |
|---|---|
| **Blank** | Nothing came back |
| **Shaky** | Got the gist, missed the substance |
| **Got it** | Solid recall |
| **Easy** | Immediate and complete |

Rate honestly. The rating feeds directly into when the concept next appears —
inflating it means the card comes back too late, when you have genuinely
forgotten it.

This step makes no API calls. It costs nothing and works offline.

### Step 2 — Lesson (1 model call)

One new concept per day, at most. While it generates, you will see the model's
reasoning summary streaming in — this is `thinking.display: "summarized"` doing
something real, and it is on the syllabus.

The lesson arrives in a fixed shape:

1. **A worked example first.** The thing done correctly, with the reasoning
   visible, before any explanation. Read it before you read the explanation —
   the ordering is deliberate and it is one of the most robust findings in
   instructional design.
2. **The explanation**, building on the example rather than restating it.
3. **A named misconception**, called out and refuted. Not a generic warning — a
   specific wrong belief that people actually hold about this concept.
4. **Three to five key takeaways** — the things that should survive if
   everything else is forgotten. These become your warm-up card for this concept.
5. **Sources**, linking back to the documentation the lesson drew on. The tutor
   may only cite URLs it was given, so these are real links, not invented ones.

At the bottom, if enabled, is a token-usage footer: input, output, cache read,
cache write, latency. Worth glancing at.

Tap **Mark as read** when finished.

### Step 3 — Quiz (1 model call, plus 1 if you write free text)

Four to eight questions mixing today's concept with older ones. The mixing is
deliberate — interleaved practice is harder in the moment and measurably better
for retention than answering ten questions about one topic in a row, because it
forces you to work out which idea applies rather than pattern-matching to
whatever you just read.

Question types vary: multiple choice, multiple select, short answer, critique
(here is some flawed code or a bad prompt — what is wrong with it), and
prediction (what does this do before you are shown).

**Before submitting each answer, state your confidence:** Guessing, Unsure,
Fairly sure, or Certain.

Answer this honestly. It is not scored and it is not judged. It is compared
against whether you were actually right, and the gap is what produces the
calibration reading on the Progress screen. If you always say "Certain" it
measures nothing.

After submitting, you see whether you were right, an explanation covering both
why the correct answer is correct and why the tempting wrong answer is tempting,
and — if you were confident and wrong — a specific note about it. That
combination is the one worth paying attention to.

Multiple-select questions award partial credit by overlap, so a near miss is not
scored the same as a guess. Free-text answers are graded by the model after the
quiz finishes.

### Step 4 — Hands-on task (2 model calls)

A task you do somewhere else and bring back. It might be writing a prompt,
building something in Claude Code, running a request against Bedrock and
analysing what came back, or explaining a concept in your own words.

**The rubric is shown before you start.** Three to five criteria with weights and
a description of what full credit looks like on each. Hidden rubrics teach people
to guess at what a grader wants instead of at the actual skill.

**The scope grows with your mastery.** The same concept produces very different
tasks depending on where you are. At low mastery you get numbered steps and are
told exactly what to submit. At high mastery you get a goal, a hard constraint,
and are expected to defend your design decisions and say what you would measure
to know it worked. This is the "tasks increase in scope as my knowledge
progresses" behaviour, and it is computed rather than guessed — a concept's own
difficulty sets the floor, demonstrated mastery raises the ceiling, and the scope
never jumps more than one tier above the concept's own difficulty.

Go and do the work. Come back, paste it in, tap **Submit for grading**.

You get back a weighted score, a per-criterion breakdown with justifications
quoting your submission, written feedback leading with what you got right,
specific gaps tied to rubric criteria, and a single most-useful next action.

The pass bar is 70%. Below that the concept stays in active rotation. Graded
tasks count as applied work and carry their own weight in your mastery estimate,
separately from quiz performance.

> If you do not yet have an AWS account, tasks on AWS concepts adapt — you will
> be asked to reason about a request, write the code, or read a policy rather
> than provision live resources.

### Step 5 — Reflection (free)

One question asking you to explain the day's material in your own words, or to
relate two concepts and say where confusing them would cause a real problem.

It is stored and never graded. The value is entirely in the writing: if you
cannot explain something plainly, you find out here rather than in a code review.
You can skip it, and you should not.

Finishing the last step completes the session and advances your streak.

---

## Part 4 — The other screens

### Progress

Four headline numbers — concepts mastered, started, total, and due right now —
plus overall mastery across the whole curriculum.

**Calibration** shows how well your confidence tracks your accuracy, as a bar
either side of a centre line, with a plain-language reading: *"Well calibrated"*,
*"Slightly overconfident on a few topics"*, *"Overconfident: you're often certain
on answers you get wrong"*. This is the number most worth watching. It is
computed from every confidence rating you have given.

**Fading** lists concepts you are most likely to have forgotten, with an
estimated recall percentage derived from an exponential forgetting curve over
your review interval. These are what the scheduler will surface next.

**Tracks** shows per-track progress. Tap one to expand it into its concept list,
where each concept shows its state — locked, available, learning, in review, or
mastered — its difficulty tier, and its mastery bar. Locked concepts tell you
which prerequisite is holding them.

### Library

Every lesson you have read, searchable by title, concept or takeaway. Lessons are
cached rather than regenerated, so reopening one costs nothing and shows you
exactly the text you read the first time.

The Library has two shelves, switched with the segmented control at the top.

**Lessons** is everything the tutor has written for you.

**My files** is PDFs you add yourself — papers, specs, printed notes. Tap **+**,
pick one or more PDFs from anywhere the Files app can reach, and they appear in
the list with a first-page thumbnail, page count and size. Tap one to read it in
the app.

Files are **copied onto the device**, not linked. That matters: the URL a
document picker hands over is a temporary, security-scoped handle that can point
at an iCloud Drive file which has not been downloaded, so a link would fail
exactly when you are offline and wanted it most. Copying is what makes offline
reading real. The cost is disk space, and the shelf shows the running total.

The reader remembers where you stopped, so a 300-page specification reopens on
the page you were on rather than at the cover. Long-press a file to delete it,
or rename and share from the menu inside the reader.

Only PDFs are accepted, and the file's actual content is parsed before it is
accepted — a `.txt` renamed to `.pdf` is rejected at import rather than becoming
a library entry that can never be opened. Password-protected and damaged files
are refused with a reason. If you pick several at once and some fail, the good
ones are still added and only the failures are reported.

### Settings

Provider choice, credentials, model selection, region, daily goal, documentation
sync, and profile management. Also where you switch or delete profiles.

### Request inspector

Under Settings → **Request inspector**. Every model call the app has made this
run, with model, endpoint, token counts, cache reads and writes, latency, and an
estimated cost. At the top: totals for the run and your cache hit rate.

This is deliberately prominent rather than hidden behind a debug flag. Someone
studying AI engineering should be watching their own token spend and cache
behaviour rather than reading about someone else's. If the cache hit rate stays
at zero after several sessions, something in the prompt prefix is changing
between requests — which is exactly the diagnostic exercise the caching lessons
describe.

Cost figures use Anthropic list prices. Bedrock is billed separately by AWS at
its own rates, and the UI says so.

---

## The curriculum

109 concepts across 7 tracks, authored as a prerequisite graph. At one new
concept a day, roughly five and a half months of material.

| Track | Concepts | Covers |
|---|---|---|
| **Prompting & Context Engineering** | 14 | Request anatomy, being explicit, structure and delimiters, examples, output shaping, context budgets, context engineering, prompting long-horizon agents |
| **The Claude API** | 18 | Messages endpoint, content blocks, stop reasons, streaming, adaptive thinking, effort, prompt caching and its silent invalidators, structured outputs, batches, files, cost |
| **Tool Use & Agents** | 17 | Tool definitions and schemas, the agentic loop, parallel calls, server-side tools, MCP, the advisor tool, tool surface design, Managed Agents, subagent fan-out |
| **Agentic Development** | 16 | Claude Code as a harness → memory, hooks, skills, subagents, plugins, the sandbox, worktrees, routines, the Agent SDK |
| **Evaluation & Reliability** | 9 | Why evals, sourcing cases, choosing graders, LLM judges and their biases, train/test splits, hillclimbing, regression testing, model migration |
| **AWS & Amazon Bedrock** | 23 | AWS accounts, IAM, credentials, SigV4, the CLI; then Bedrock from what-it-is through InvokeModel, streaming, guardrails, knowledge bases, agents, quotas, observability, VPC isolation, and production architecture |
| **Production AI Engineering** | 12 | Key management, latency, retries, observability, RAG, multimodal, refusal handling, approval gates, cost control, prompt injection defense, and a capstone |

### How progression works

Every concept sits in one of five states:

- **Locked** — prerequisites not yet met
- **Available** — unlocked, never studied
- **Learning** — seen, mastery still below threshold
- **Review** — good enough to build on, resurfacing on schedule
- **Mastered** — sustained high performance across spaced repetitions

A concept unlocks when all its prerequisites reach **Review** — not full mastery,
or the tree would barely open. Mastery requires sustained performance across at
least four repetitions with an interval of three weeks or more, which cannot be
rushed.

New concepts are chosen by lowest difficulty tier first, then by which track you
have advanced least far in. That spread is deliberate: it keeps the AWS material
moving alongside the prompting material rather than after it, and it gives the
interleaved quizzes something to work with.

**No more than seven concepts stay in flight at once.** Past roughly that many
partially-learned ideas, everything degrades — so new material stops until the
backlog clears. If you notice you are getting review-only days, that is the
system working, not stalling.

The graph is validated as a unit test: no cycles, no dangling prerequisites,
every concept reachable from a root, and tiers monotonic — nothing is rated
easier than its hardest prerequisite.

---

## How the learning design works

Each of these is load-bearing rather than decorative.

**Spaced repetition (SM-2), with two departures.** The textbook algorithm treats
"answered correctly four times" as knowing something. It is not — you can pass
four easy recalls and still be unable to apply the idea. So progression gates on
a separate mastery estimate, and the interval only decides *when* a question
returns. The second departure: being wrong while *certain* schedules the card for
tomorrow regardless of interval, because you have no internal signal telling you
to review it.

**Retrieval practice before new material.** Every session opens with recall. This
is the highest-value part of the app and it is deliberately free of model calls,
so it can never be blocked by a rate limit, a missing key, or no signal.

**Interleaving.** Quizzes mix concepts rather than blocking on one. Harder in the
moment, better for retention and for learning to discriminate between similar
ideas.

**Worked examples, then faded practice.** Lessons lead with a solved example.
Tasks start heavily scaffolded and progressively remove the scaffolding as
mastery rises.

**Confidence calibration.** Stated before each reveal, compared against
correctness, tracked per concept, surfaced on Progress.

**Elaborative interrogation.** Lessons name a specific misconception and refute
it, rather than only presenting the correct version — which leaves the wrong
version untouched.

**Self-explanation.** The closing reflection, ungraded on purpose.

---

## Keeping the curriculum current

Content ages in three layers, and each updates differently.

**Lesson prose is generated per session**, so it always reflects whatever is in
the corpus at the time. Nothing to update.

**The document corpus refreshes on sync.** Curated sources are revalidated with
ETags, and beyond those the app crawls the `llms.txt` indexes that both
Anthropic documentation sites publish — 831 pages between them — plus the AWS
Bedrock sitemap. Pages written *after* the syllabus was authored are therefore
still found, which a hardcoded list of 49 URLs can never manage.

Discovered pages supplement the curated ones rather than replacing them. A
hand-picked source encodes an editorial judgement about which page best teaches
a concept; a keyword match does not. Retrieval scores curated sources well above
discovered ones, so a discovery fills a gap but never displaces a deliberate
choice.

The matching is deliberately conservative. Scoring is carried by the concept's
id tokens and title words, with words from its key ideas capped so they can only
break ties — a flat keyword count matched "hooks" to a page about cloud
environments, and a wrong page is worse than no page because it consumes a fixed
retrieval budget. At the tuned threshold roughly three quarters of concepts gain
a page, and the ones that don't correctly get nothing.

Anthropic docs are fetched as Markdown (`page.md`) rather than scraped HTML, so
the model gets clean prose instead of the output of a tag-stripping regex.

**The syllabus updates without an App Store release.** `curriculum.json` is
published in this repository, and the app checks the raw URL on demand. A
downloaded syllabus is adopted only if it is both newer than the bundled copy
*and* passes full validation — a dangling prerequisite would lock concepts
permanently, so the graph is checked before adoption, not after. The bundled
copy is the floor and is never removed, so a bad publish, a corrupt cache, or a
first launch offline all degrade to a working app.

Progress is keyed by concept id, so it survives updates: concepts that still
exist carry on, new ones appear as available, and rows for removed concepts sit
dormant rather than being deleted, in case the concept returns. **Settings →
Curriculum** shows the current version and where it came from, checks for
updates, and can revert to the bundled syllabus.

Adding a concept is therefore: edit `curriculum.json`, bump `version`, run the
curriculum tests, commit. Every install picks it up on its next check.

## Where content comes from

There is no public "Claude tutorials API". The material lives across Anthropic's
documentation, the courses and cookbook repositories, and AWS's Bedrock guide.
So the app works in three layers:

**The syllabus is authored and versioned in this repository** —
`Praxis/Curriculum/Resources/curriculum.json`. Concepts, ordering, prerequisites,
learning objectives, key ideas, misconceptions, and source references. This is
what stops generated lessons drifting into a different curriculum.

**Documentation sync builds a local corpus.** The 49 source URLs are fetched,
with HTML reduced to text, Markdown passed through, and Jupyter notebooks
stripped to their markdown and code cells. ETag and Last-Modified revalidation
keeps refreshes cheap.

**Retrieval grounds each lesson.** For a given concept, the app scores corpus
documents — an explicit curriculum tag outranks keyword coincidence — then picks
the most relevant paragraphs within a fixed character budget and re-emits them in
document order so the excerpt still reads as prose. That, not the whole corpus,
is what goes into the prompt.

Lessons may cite only URLs from the supplied list, so the tutor cannot invent a
plausible-looking documentation link.

---

## What it costs to run

Roughly four to five model calls per session:

| Step | Model | Why |
|---|---|---|
| Warm-up | — | No call |
| Lesson | Opus 5.5, medium effort | Needs the reasoning |
| Quiz generation | Haiku 4.5 | Mechanical work from an already-written lesson |
| Short-answer grading | Haiku 4.5 | Only if you wrote free text |
| Task generation | Opus 5.5, medium effort | Design judgement |
| Task grading | Opus 5.5, medium effort | Judgement, and it must be accurate |
| Reflection | — | No call |

Effort is chosen per model rather than fixed. Level names do not mean the same
amount of thinking across models — Opus 5.5 defaults to `medium` and matches
Opus 5 at `high` on this kind of work — so sending one value to every model
quietly overpays on the newer ones.

The stable part of every system prompt — the tutor instructions, identical on
every request the app makes — sits behind a one-hour cache breakpoint, with
per-request content after it. That is the whole reason for the ordering, and the
request inspector lets you confirm it is working.

Exact cost depends on your models and how much source material gets retrieved.
Watch the inspector for a few days and you will have a real number rather than
an estimate — which is, not coincidentally, the habit the cost lessons are
trying to build.

---

## Multiple profiles

Profiles are fully local. No accounts, no login, no server, no sync.

Each profile keeps its own progress graph, review schedule, mastery estimates,
calibration history, streak, lesson library and task submissions. Switching is
instant — tap your avatar on the Today screen, or use Settings → Switch profile.

Two things are shared across profiles: the documentation corpus (it is public
documentation, and refetching it per profile would waste bandwidth and rate
limit) and the credentials in the Keychain.

Deleting a profile removes everything belonging to it — progress, lessons,
quizzes, tasks, reflections. This cannot be undone.

---

## Privacy and data

Everything lives on the device. There is no backend, no analytics, no telemetry,
and no account.

**Credentials** are in the iOS Keychain, device-only, excluded from iCloud
Keychain and from backups. They are sent only to the provider you chose, as an
`x-api-key` header or a SigV4 signature.

**Your learning data** — progress, submissions, reflections — is in a local
SwiftData store. It is not transmitted anywhere. Delete the app and it is gone;
there is no export yet.

**What does leave the device:** the content of generation requests. Your name,
your stated prior knowledge, the concept being taught, retrieved documentation
excerpts, and — when you submit a task — the work you paste in. That goes to
Anthropic or to AWS depending on your provider, and is subject to their terms.

**The request inspector** keeps prompts and responses in memory only, for the
current run. Nothing is persisted.

---

## Architecture

For anyone modifying this.

```
Praxis/
├─ App/              Entry point, environment, SwiftData repository
├─ DesignSystem/     Palette, components, Markdown renderer
├─ Models/           SwiftData entities and the model catalog
├─ Curriculum/       Concept graph types, store, curriculum.json
├─ Providers/        LLMProvider protocol, Anthropic, Bedrock, SigV4, event stream
├─ Learning/         SM-2, mastery model, session planner
├─ Generation/       Prompts, JSON schemas, TutorService
├─ DocsSync/         Fetching, text extraction, retrieval
└─ Features/         Profiles, Today, Lesson, Quiz, Tasks, Progress, Library, Settings
```

**The learning engine is pure.** `SpacedRepetition`, `SessionPlanner` and
`MasteryModel` operate on plain values, not on SwiftData objects. That is why
they are thoroughly testable, and why a scheduling bug can never leave a
half-updated managed object behind.

**Persistence uses foreign keys, not relationships.** Child records carry a
`learnerID` rather than a SwiftData relationship, because `#Predicate` traversal
across relationships has been unreliable. The cost is an explicit cascade in
`LearningRepository.deleteLearner`; the benefit is predictable queries and a
straightforward path to CloudKit sync later.

**The provider layer is genuinely abstract.** One protocol, two implementations,
and everything above it is provider-agnostic — which is what makes the Settings
toggle real rather than cosmetic.

| | Anthropic | Bedrock |
|---|---|---|
| Endpoint | `api.anthropic.com/v1/messages` | `bedrock-runtime.<region>.amazonaws.com/model/<id>/invoke` |
| Auth | `x-api-key` header | SigV4, service `bedrock` |
| Model ID | `claude-opus-5`, in the body | `anthropic.claude-opus-5`, in the URL path |
| Version | `anthropic-version` header | `anthropic_version` body field |
| Streaming | Server-sent events | Binary `vnd.amazon.eventstream` frames |

The streaming difference is the interesting one. The JSON events *inside*
Bedrock's binary frames are byte-identical to the first-party SSE payloads, so
`StreamAccumulator` is shared between both providers and each provider stays
thin. SigV4 signing and the event-stream decoder are hand-written with no AWS SDK
dependency, and the signing is tested against AWS's published reference vectors.

**Structured output uses strict tools** rather than a response-format parameter,
because strict tool use is supported on both providers and the newer response
formats are not.

**Grading is reconciled.** The model returns both a per-criterion breakdown and
an overall score, and they sometimes disagree. The app recomputes the overall
from the weighted breakdown, because the breakdown is what the learner sees — a
headline score contradicting its own justification destroys trust in grading
entirely.

---

## Theming

The visual design is Claude-derived: warm paper neutrals, a clay accent, a serif
face for lesson titles. All of it lives in `Praxis/DesignSystem/Theme.swift`,
and nothing outside that file contains a color literal or a raw font size.

Re-skinning the app is therefore a single-file edit — roughly fourteen values
covering surfaces, text, accent, semantic states and the seven per-track hues,
each defined for light and dark side by side. Two things are worth knowing
before you change the accent:

1. **Change it in two places.** `Palette.accentHex` in code, and `AccentColor`
   in the asset catalog, which system chrome reads instead. A unit test asserts
   they match, so you will be told if you forget.
2. **The foreground on top of the accent is derived, not fixed.** It flips
   between white and dark ink based on the accent's luminance, so a pale accent
   will not leave you with invisible button labels.

What is *not* configurable: there is no theme picker in the app. Light and dark
follow the system setting and cannot be overridden in-app, and there is no
user-selectable palette. Making the theme switchable at runtime would mean
replacing the static palette lookups with an environment-injected theme object —
contained, but it touches every view.

## Localization

The app is internationalization-ready: the code is prepared, the string catalog
is wired, and no language has been translated yet.

### Adding a language

1. In Xcode, select the project → **Info** → **Localizations** → **+**, and pick
   a language.
2. Build once (**⌘B**). Xcode extracts every localizable string into
   `Praxis/Resources/Localizable.xcstrings`. The catalog is checked in empty on
   purpose — extraction is a build step, not something to hand-maintain.
3. Open the catalog and translate. Strings carry translator comments explaining
   what each one is and what the placeholders mean.

### What is and isn't translated

Everything a learner reads is localizable: SwiftUI `Text` literals are picked up
automatically, and the strings that live in Swift enums — session step names,
confidence and recall labels, calibration readings, every error message, model
picker guidance — go through `String(localized:)` with comments.

Deliberately **not** translated, because translating them would be a bug:

- SF Symbol identifiers, which are icon names rather than text
- Product names: *Anthropic API*, *Amazon Bedrock*, model display names
- Endpoint hostnames
- Everything in `Prompts` — those are instructions to the model, not UI. They
  also have to stay byte-stable for prompt caching to work.

### Plurals and numbers

Plural forms use automatic grammar agreement — `^[\(count) concept](inflect: true)`
— rather than an English `count == 1 ? "" : "s"` ternary, which is wrong in most
languages and badly wrong in ones with more than two plural forms.

All user-facing numbers go through `Format` in
`Praxis/DesignSystem/Formatting.swift`, so decimal separators, grouping, percent
placement and currency symbol position follow the locale. Costs stay in USD —
that is what both providers bill in — but format per locale.

One deliberate exception: numbers inside prompts are *not* locale-formatted.
Those are read by the model, and a German device must not send `50 %` where an
American one sends `50%`.

### Right-to-left

Layout uses leading/trailing throughout, so it mirrors. One place needed a fix:
the calibration bar on the Progress screen positioned itself with absolute
`offset(x:)`, which SwiftUI does not flip, so it drew on the wrong side of the
axis while its labels mirrored correctly. It is now centre-anchored and mirrors
explicitly.

### Lessons in your language

Generated content follows the device language too. When the locale is not
English, the tutor is told to write the lesson, quiz and feedback in that
language — with an explicit carve-out that code, API parameter names, model
identifiers, headers, commands and URLs stay in English. Those are exact strings
the learner will type, and a translated one is a wrong one.

That instruction sits *after* the prompt cache breakpoint, so supporting other
languages costs nothing in cache hit rate.

**This part is untested against real output.** The instruction is sound, but
whether Opus 5 writes good pedagogical German or Hindi for this material is an
empirical question that needs a native speaker to judge.

## Troubleshooting

**Xcode shows an empty project.** You are on Xcode 15 or earlier. Upgrade, or run
`xcodegen generate`.

**"No API credentials yet" on the Today screen.** No provider is configured. Add
one in Settings. Warm-up reviews still work.

**Bedrock returns 403 AccessDenied.** Two distinct causes, and the message
distinguishes them: either the IAM principal lacks `bedrock:InvokeModel`, or
model access has not been granted for that model in that region. Check both.
Region mismatch is the more common one.

**Bedrock returns ValidationException on the model ID.** Either the `anthropic.`
prefix is missing, or the model requires an inference profile rather than a bare
ID in that region.

**Rate limited (429).** The app surfaces the retry-after value. Wait it out.

**Documentation sync reports failures.** Expected for some sources —
documentation sites restructure. Failures are listed per-source. Lessons for
affected concepts still generate, with weaker grounding.

**Cache hit rate stays at zero.** Check the request inspector after several
lessons. If it is still zero, something in the prompt prefix is varying between
requests. This is a real diagnostic exercise and the caching lessons walk through
how to find it.

**"The model did not call emit_lesson."** The model answered in prose instead of
calling the structured-output tool. Usually transient — retry. If persistent on
one concept, the concept's key ideas may be triggering a refusal.

---

## Known gaps

**Never compiled.** Stated again because it is the most important thing to know.

**No app icon.** The asset slot exists and is empty.

**No eval for the tutor itself.** Grading quality is unvalidated, which is an
awkward omission in an app that teaches you to build evals. The honest fix is a
small set of submissions with known grades, run against the grading prompt. This
is the first thing worth adding.

**No export.** Your learning history cannot be extracted. Deleting the app loses
it.

**No CloudKit sync.** Deliberate for v1, and the foreign-key data model makes it
a contained change rather than an untangling.

**Documentation sync is sequential.** A minute or two on first run. Concurrency
would burn GitHub's anonymous rate limit immediately, so it is sequential on
purpose, but a token plus bounded concurrency would improve it.

**Bedrock model IDs assume plain identifiers.** Raw ARNs would need the second
URI-encoding pass SigV4 requires for non-S3 services.

**No Dynamic Type support.** All font sizes are fixed points, so the app ignores
the system text-size setting. This matters for accessibility and it is the
largest known gap in the UI. Fixing it is a design pass rather than a mechanical
one — the layout needs checking at accessibility sizes — so it was flagged
rather than guessed at. The smallest role in the type scale is 10pt, below
Apple's 11pt legibility guidance, and is used only for uppercase chips and unit
suffixes.

**No theme picker.** See [Theming](#theming).

---

## License

None yet. Add one before sharing this further.
