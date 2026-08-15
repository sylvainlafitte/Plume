# Plume — local meeting transcription & AI summaries

> **Status: design record.** This was written before implementation and captures *why* each
> decision was made. As phases land it becomes history rather than instruction — for how the
> code actually works today, [AGENTS.md](../AGENTS.md) is the source of truth and wins any
> disagreement. Progress and dead ends live in [PROGRESS.md](PROGRESS.md).

## Context

Build a minimalist macOS meeting-notes app: record a call, transcribe with speaker
attribution, generate a templated AI summary with a local model, keep manual notes taken
during the call, and store everything as markdown that can be edited and re-summarized.

Two OSS projects were evaluated as starting points:

- **[OpenOats](https://github.com/yazinsai/OpenOats)** — does nearly everything, but ~2.1 MB
  of Swift across 120 files, a rejected UI, and many unwanted features.
- **[Quill](https://github.com/digimata/quill)** — 1,303 lines across 13 files, the right
  minimalist spirit, but no summaries, no GUI, and two-party-only speaker labelling.

**Decision: fork Quill, use OpenOats as a read-only design reference.** Both already depend
on [FluidAudio](https://github.com/FluidInference/FluidAudio), so real diarization is an unused
API surface in a dependency Quill already ships, not a new subsystem.

Rejected: forking OpenOats and deleting. Its unwanted features are not separable modules
(`SettingsStore.swift` 87 KB, `SessionRepository.swift` 85 KB, `LiveSessionController.swift`
76 KB), and the end state would still be the rejected UI.

*This plan was adversarially reviewed; corrections are folded in. Claims are marked
**[verified]** or **[unverified]** so nothing false-confident survives into implementation.*

## Confirmed decisions

| Decision | Choice | Consequence |
|---|---|---|
| Live vs batch | **Post-call batch** | Avoids the streaming path that makes OpenOats 36× larger |
| Language | **English only** | Keep Parakeet v2; multilingual v3 is a one-line change (F2) |
| Audio | **Deleted as soon as the transcript is written** | No re-runs, ever — see R3 |
| Layout | **One `.md` per meeting** | Written when diarization completes, then edited by region (F7, F8) |
| Ask | **One meeting at a time** | Reuses Phase 4's chunking; no embeddings, no cross-meeting index |
| Packaging | **`.app` bundle** | TCC grants bind to bundle identity; login item via `SMAppService` |
| Call detection | **None; manual only** | Drops a ~150-line subsystem; camera trick recorded in F5 |
| Notes panel | **Pill / strip / wrap-up.** Free-text notes throughout | The primary surface for a fresh meeting — see F8 |
| Transcript in the UI | **Never displayed** | No transcript view anywhere; it exists as summarizer input and as text in `meeting.md` |
| Summarization trigger | **Explicit, after wrap-up notes** | Not automatic on stop — see F8 and R10 |
| Templates | **Default runs on first generate; switch and regenerate** | Markdown files in a folder you can open — see F9 |
| Settings | **Small window, config file is the source of truth** | Shell built in Phase 1; each phase adds its pane — see F10 |
| Ask placement | **A third tab** (Notes / Summary / Ask) | *Reversed in Phase 6* once the panel and history began sharing one view — see F11 |

**Environment [verified]:** M1 Pro, 16 GB, macOS 26.5.1, Xcode 26.4.1, Swift 6.3.1,
Ollama 0.32.9 with `gemma4:latest` (9.6 GB). 16 GB is the binding constraint (R5).

## Key findings

**F1 — Use `OfflineDiarizerManager`, not the streaming diarizer. [verified]** OpenOats uses
LS-EEND because it transcribes live; we have complete files on disk. FluidAudio's own AMI-SDM
benchmarks (`Documentation/Benchmarks.md:631, 865, 913`):

| Pipeline | DER | Max speakers |
|---|---|---|
| **`OfflineDiarizerManager`** (pyannote community-1 + VBx) | **10.6%** | unbounded |
| `LSEENDDiarizer` (OpenOats' choice) | 20.7% | 4–10 by variant |
| `OfflineSortformerDiarizer` | 56.7% — a trap for long multi-speaker audio | 4 |

Models are 21.4 MB, CC-BY-4.0, no HuggingFace token — FluidInference re-hosts converted CoreML
bundles, so pyannote's usual auth requirement doesn't apply. `process(_ url:)` is memory-mapped.
*(Throughput is not compared: the published 323× is M5 Pro, LS-EEND's 74× is M4 Max CPU-only.
Different hardware, not a valid ratio.)*

Config, all one-liners:
- `clusteringThreshold: 0.7` — the 0.6 default undercounts speakers (degrades to 15.5% DER).
  **But** 0.7 was tuned against 4-speaker AMI meetings and still over-counts there. A personal
  tool's modal meeting is a **1:1**, where a merge-averse threshold splits one voice into
  S1/S2. Validate on a real 1:1 before locking it, and pass `withSpeakers(max:)` when the
  participant count is known — the mic track already isolates you, so system-track speakers =
  participants − 1.
- `segmentationStepRatio: 0.1` + `minSegmentDuration: 0.0` — 15.07% → **13.89%** DER on
  VoxConverse at half throughput. For post-call batch that's free accuracy.
- `zeroVoteReembed(enabled: true)` — off by default; without it zero-vote frames tie-break to
  cluster 0, "silently absorbing whole speaker turns into the surrounding speaker's segment."
  Exactly our failure mode.

**F2 — ASR stays on Parakeet v2 [verified].** FluidAudio 0.15.5 defaults to `.v3` (25 European
languages, inferred acoustically). Quill pins `.v2`, which is marginally better on English
(2.1% vs 2.5% WER). Keep v2 — and note the language question is now a one-line change, not an
engine-selection layer. Required model set is 464 MB (Quill's "~600 MB" comment is stale).

**F3 — Ollama context, corrected.** Three separate facts:
- Ollama 0.32.x picks `num_ctx` by VRAM tier (`server/routes.go:2032`): ≥47 GiB → 262144,
  ≥23 GiB → 32768, else **4096**. On a 16 GB Mac `recommendedMaxWorkingSetSize` ≈ 10.7 GiB, so
  we land on **4096** [verified] — right here, but not a universal constant.
- The OpenAI-compatible `/v1` endpoint has no `options` passthrough; Ollama's own compatibility
  docs state "The OpenAI API does not have a way of setting the context size for a model"
  [verified]. So use the native **`/api/chat`**. *(An earlier draft cited ollama#9519 for this;
  that issue is about `/api/generate` on 0.5.12 and does not support the claim.)*
- Over-length prompts are handled by `truncate`/`shift`, both defaulting true — the front is
  silently dropped. **Send `truncate: false, shift: false`** so it becomes an HTTP error we can
  surface. This is the plan's own fail-loudly doctrine and it's free.

**Consequence — revised 2026-08-14 by [Spike C](../spikes/num-ctx/RESULTS.md).** The plan set
`num_ctx: 8192` and always chunked, on the assumption that a larger context might not fit.
Measurement says otherwise: gemma4's KV cache costs **16 KiB/token**, because only 4 of its 42
layers carry a full-context cache (20 use a 1024-cell sliding window, 18 share KV). Totals:
8192 → 168 MiB, **32768 → 552 MiB**, 65536 → 1064 MiB. Generation verified at 32768: 33.6 tok/s,
100% GPU.

**So use `num_ctx: 32768`.** A 1-hour meeting is ~15k tokens and summarizes in a *single pass*,
which removes cross-window context loss for the common case. Map-reduce stays implemented but
becomes the **fallback past roughly 2.5 hours**, not the default — it is what keeps the
no-silent-truncation guarantee true for any input length.

Still send an explicit `num_ctx`: it sets `usesAutomaticNumCtx = false` and so forgoes Ollama's
automatic context reduction on load OOM (`server/sched.go:757`), which is an acceptable trade
now that the value is measured rather than guessed.

**F4 — Floating panel configuration [verified against source].**
*Superseded in part during Phase 5: the pill is now a **separate borderless window**, because a
`.titled` window's `contentLayoutRect` collapses to zero height below ~28pt. And again in
Phase 6: this configuration describes the **recording** window only — wrap-up is an ordinary
`NSWindow` at normal level, with none of the floating/non-activating settings below. See
AGENTS.md §4.*

```swift
styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView]
titlebarAppearsTransparent = true
titleVisibility = .hidden
isOpaque = false; backgroundColor = .clear
isFloatingPanel = true; level = .floating
collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
animationBehavior = .utilityWindow
```

`.nonactivatingPanel` is load-bearing: clicking doesn't activate Plume, so Zoom stays frontmost.
`.titled` (not `.borderless`) is what lets the panel become key so we can type into it — no
`canBecomeKey` override needed. *(An earlier draft of this plan specified `.borderless` and
then invented a workaround for the breakage that caused. OpenOats uses `.titled`.)*

Do **not** mutate `styleMask` after init to switch strip↔expanded — there's an AppKit/WindowServer
desync where `kCGSPreventsActivationTagBit` is only set at init, after which typing silently
fails. Resize, or use two panels.

Accept the real cost: while the panel has keyboard focus, **Zoom's in-meeting shortcuts (mute,
push-to-talk) will not fire.**

**Confirmed by [Spike B](../spikes/panel/RESULTS.md) 2026-08-14:** keystrokes land in a SwiftUI
`TextField` inside the panel while the other app keeps frontmost status. `.titled` gives key-window
status without `.nonactivatingPanel` surrendering the foreground app — no `canBecomeKey` override
needed, as predicted.

**B2 — ~~`sharingType = .none` no longer hides windows from screen shares.~~ CORRECTED
2026-08-14 by [Spike B](../spikes/panel/RESULTS.md): it still works.** Measured on macOS 26.5.1
against QuickTime's ScreenCaptureKit-backed recorder — the `.none` panel was absent from the
capture while an otherwise identical `.readOnly` control panel appeared normally.

The original claim came from an Apple DTS statement that "there are no public APIs for
preventing screen capture." That is Apple declining to *guarantee* exclusion as a security
boundary — still true — not evidence the mechanism is non-functional. This was tagged
`[verified]` when what had been verified was that Apple says it, not that it fails here. Treat
the remaining `[verified]` tags with that distinction in mind: some are citations, not
measurements.

**Design accordingly:** keep `sharingType = .none`; it does real work. Keep the explicit hide
hotkey too — defence in depth for the capture paths not individually tested (Zoom, Teams, Meet,
browser `getDisplayMedia`) and for any future regression. Still make **no privacy promise** in
UI copy: it is best-effort, it says nothing about a phone pointed at the screen, and Apple
offers no guarantee.

**F8a — Summarize is pinned below the tabs, and each surface opens on a different tab.**
*Added during Phase 6.* Putting the action inside the Notes tab made the default tab
load-bearing: it decided whether the action was even reachable. Pinned below the tabs it is
always available, so the default can simply follow what each surface is for — the panel opens
on **Notes** (you are writing a record), the history window on **Summary** (you are reading one
back). Fixed per surface, never per meeting: a default that varied with the selection would make
the tab jump as you moved down the list. The Summary empty state carries the instruction, so a
never-summarized meeting opened in history is not a dead end.

**F8 — The panel is the whole post-meeting flow, and summarization is gated on a human.**
Stopping the recording does not end the interaction. The panel stays up and expands, so final
thoughts can be added while transcription runs, and only then is the summary generated:

```
[pill]       62×22 capsule: red dot + elapsed. Click to expand.  ⌘M collapses
     ↕
[recording]  strip: elapsed, Stop, notes editor, ⌘T timestamp
     ↓ stop
[wrap-up]    Notes tab (editor + template + Summarize) │ Summary tab (result + speakers)
     ↓ transcription + diarization finish in the background (~30-60s for an hour)
[ready]      Summarize enabled → streams into the Summary tab
```

*Revised during Phase 5:* Summarize is the primary CTA **under the notes**, not on the
Summary tab — notes are the input and the summary is the output, so the action belongs
where you finish working, and editing then regenerating never means bouncing tabs. The
Summary tab is a result view: summary plus speaker list, no controls.

Three consequences worth stating plainly:

- **Summarization becomes a separate, human-triggered stage.** The pipeline is no longer
  stop → … → summary; it is stop → transcribe → diarize → *wait* → summarize, and the stage
  machine gains an `awaiting_wrapup` state. **`meeting.md` is written as soon as diarization
  finishes**, with `## Summary` reading `*pending*` — not at summarize time. A failed Ollama
  call or an abandoned wrap-up must never leave the transcript unwritten, and the summary step
  then only ever *replaces a region in an existing file*, which is the same operation as
  regeneration rather than a special case.
- **Notes are an editable field throughout, not just at wrap-up.** *Revised during Phase 5:
  the original design appended line-by-line while recording and only became editable on stop.
  In use that was wrong — you rewrite notes as a meeting goes, and a commit-only field forces
  you to get each line right first time.* So it is one `TextEditor` in both states, saved whole
  on a 1.2s debounce. A `TextEditor`, not a markdown editor: no preview, no highlighting,
  no toolbar.
- **Because transcription is never displayed, there is no transcript view to build** — no long-list
  rendering, no virtualization, no scroll-sync. The transcript reaches the user only as text in
  `meeting.md`. This is a genuine simplification, not just a deferral.
- **Post-call, the panel should activate normally.** `.nonactivatingPanel` prevents *click-to-activate*,
  which is what we want mid-call; after stop we can call `makeKeyAndOrderFront` + `NSApp.activate`
  to get a comfortable typing surface. This also sidesteps M4 — no `styleMask` mutation, one panel.
  *(Revised in implementation: it is **three** windows, not one. `.nonactivatingPanel` lives in
  `styleMask` and so cannot be dropped after Stop — and it must be dropped, because such a window
  can be key while another app is active, where ⌘C reaches nothing. Wrap-up is therefore an
  ordinary `NSWindow`; the pill is borderless. See AGENTS.md §4.)*

**Speaker correction without a transcript view.** If the transcript is never shown, there's no way
to learn that S1 is Marie. The Summary tab lists detected speakers with two or three representative
utterances each ("S1 — *'so I think we should push the launch'*"), and supports **rename, merge,
and drop-to-`them`**. Merge is not optional polish: diarization's characteristic failure is
splitting one person across two labels, and rename alone cannot repair that. Merge rewrites both
labels to one in the transcript region and collapses the frontmatter entries.

A few representative lines per speaker is enough to put a name to a voice, and it keeps a
transcript view from reappearing by the back door. *Declined: a full read-only transcript view
with search.* It was explicitly not wanted, the transcript is one click away in `meeting.md`,
and merge closes the real gap that motivated the suggestion.

**F9 — Templates are markdown files in a folder, not a JSON store.** Everything else in Plume is
a markdown file the user owns and edits in their own editor; templates should be no different. A
template *is* a system prompt, so the file body is the prompt and the frontmatter carries the name:

```
~/Library/Application Support/Plume/Templates/
  1-1.md            # ---\nname: 1:1\n---\n<system prompt>
  standup.md
  client-call.md
```

Three ship on first run and are never overwritten afterwards, so edits survive updates. The
picker just lists the folder; "Open Templates Folder" is the entire editing UI. This deletes
OpenOats' `templates.json` + built-in reconciliation + `resetBuiltIn` machinery (~200 lines)
and stays consistent with the no-in-app-editor decision. Adding a template is dropping a file in.

*(Application Support rather than `~/Meetings/Templates/` so the meetings folder stays purely
meetings. The trade-off is discoverability, which the menu item covers.)*

**F10 — Settings: a small window, with the config file remaining authoritative.** The window
reads and writes the same `config.json` — one store, not two, so a hand-edit and a UI edit can
never disagree.

Implemented in Phase 1 (shell + folder picker, echo-cancellation and auto-transcribe toggles),
along with the fix it forced: `Config` was re-parsing JSON on every accessor call. It is now a
typed `Settings` struct behind an mtime-keyed cache, so hand-edits still take effect without a
relaunch.

**Panes still to add, by the phase that introduces them:**

| Setting | Key | Phase | Why it needs UI |
|---|---|---|---|
| Expected participants | `expected_participants` | **2 — pending** | Caps far-end speakers (F1). Default 2 = a 1:1. Currently config-file only, and it is the setting most likely to need changing per meeting |
| Echo filter | `transcript_echo_filter` | **2 — pending** | Default on. Config-file only today; belongs next to the mic settings since the two interact |
| Ollama model | — | 4 | Populate from `/api/tags`; typing a model name is error-prone |
| Summary template default | — | 4 | Lists the templates folder |
| Panel hotkey | — | 5 | Needs a key recorder |
| Launch at login | — | deferred | `SMAppService.mainApp` — listed in Phase 1, not built |

Deliberately *not* exposed: diarizer threshold, step ratio, overlap and quality gates. They are
measured values with reasons recorded in code, not preferences — a wrong setting there produces
a subtly bad transcript that cannot be redone (R3).

**F11 — ~~Ask is a row, not a surface.~~ Reversed during Phase 6: Ask becomes a third tab.**
The argument below was that a tab living only in the post-call panel would be in the wrong
place for old meetings — sound at the time, when the panel and the history window were separate
implementations. Extracting the shared `MeetingDetailView` dissolved it: a tab now appears in
both surfaces automatically, which is exactly what this finding wanted and couldn't have. A tab
is also the better shape — Ask is a mode you stay in, not a control you press once — and it
leaves the bottom edge to the summarize bar instead of two controls competing for it.
*Original reasoning follows.*

 Your instinct is right that it belongs with the summary,
but it shouldn't be a third tab: Ask is most useful on *old* meetings, and a tab that only exists
in the post-call panel would be in the wrong place for that. Make it an input row pinned under
the Summary view — one SwiftUI component, hosted in both the wrap-up panel and the history window.

Consequences: no new window, no new navigation, and Phase 7 becomes "one component plus wiring."
Answers get a "save to notes" action, which appends to the Notes region — so asking a question
can become a durable part of the meeting record rather than disappearing.

**F12 — Derive the meeting title and speaker names from notes + transcript.** This is a good idea
and it closes a gap the plan had left open: the storage layout showed
`~/Meetings/2026-08-13-1402-weekly-sync/`, but nothing ever said where `weekly-sync` came from.
Recording starts before anyone knows what the meeting is.

Signals available, strongest first — and note most live in the *transcript*, not the notes:

| Signal | Example | Strength |
|---|---|---|
| Self-introduction | "Hi, I'm Marie" | Very strong |
| Vocative addressed to the far end | You say "Thanks, Tom" → the other speaker is Tom | Strong |
| Turn adjacency after a direct address | "Marie, what do you think?" → next speaker is probably Marie | Good |
| Names written in your notes | "Marie said X", "ask Tom re: pricing" | Good, but unanchored to a label |

Notes alone can't map a name to `S1` — they tell you *who was there*, not who spoke when. Combined
with vocatives and adjacency in the transcript, a local model does this well. So fold it into the
existing summary call as **schema-constrained structured output** — Ollama's `/api/chat` supports
`format` with a JSON schema, which also bounds the injection surface, since a schema-constrained
response can't wander off into whatever a participant said out loud:

```json
{ "title": "Pricing review with Marie",
  "speakers": { "S1": {"name": "Marie", "confidence": 0.9, "evidence": "introduces herself at 00:14"} } }
```

**Suggestions, never silent rewrites.** A wrong name attributes quotes to the wrong person, which
is materially worse than an honest `S1`. So the speaker list pre-fills the rename fields with
proposals and their evidence, and one click accepts. Below a confidence floor, propose nothing.
This needs no new UI — it populates the rename/merge affordance from F8 that already exists.

**Folder naming follows from this.** The directory is created as `2026-08-13-1402` at record time
and renamed to `2026-08-13-1402-pricing-review` once a title exists — at the `diarized` stage,
after audio handles are closed and before `meeting.md` is written, which is the one moment a
rename is safe. If titling fails or is declined, the timestamp folder is a perfectly good
permanent name.

**F5 — Camera detection, if ever wanted.** `kCMIODevicePropertyDeviceIsRunningSomewhere` on
CoreMediaIO video devices reports camera-on with **no TCC permission and no green dot** — a
status read, not a capture. Deferred by decision; recorded so it isn't rediscovered.

**F6 — ASR↔diarization alignment is a data-model change, not a helper function.** FluidAudio
deliberately doesn't compose the two. The work is larger than it looks: Quill's
`TranscriptSegment` is `(start, end, text)`, and `ParakeetEngine.segments(from:)` groups up to
**60 words** before discarding the `WordTiming`s — a 60-word segment routinely spans a speaker
change. So we must (a) plumb word timings through the `TranscriptionEngine` protocol, (b) assign
a speaker per word, (c) **re-segment on speaker boundaries**, (d) re-render. This defines the
transcript data model, which is why diarization now precedes the markdown format work.

## Storage format

One directory per meeting. **`meeting.md` is written when diarization completes** — with the
summary still `*pending*` — and thereafter edited region by region. It is never the *live* write
target during a call; notes go to `.plume/notes.md` until then (F7).

```
~/Meetings/2026-08-13-1402-weekly-sync/
  meeting.md
  .plume/            # state.json, notes.md, audio — removed after the last stage
```

```markdown
---
plume: 1
title: Weekly sync
started: 2026-08-13T14:02:11+02:00
duration_s: 2834
template: standup
model: gemma4:latest
summary_generated: 2026-08-13T14:50:03+02:00
speaker_S1: Marie
speaker_S2: Tom
---

<!-- plume:notes start -->
## Notes
...
<!-- plume:notes end -->

<!-- plume:summary start -->
## Summary
...
<!-- plume:summary end -->

<!-- plume:transcript start -->
## Transcript
**[00:12] Me:** ...
<!-- plume:transcript end -->
```

- **All three regions are marked**, including Notes — Phase 5 writes it and Phase 7 reads it,
  and it's the region most likely to be restructured by hand.
- **The file exists before the summary does.** It's written when diarization completes, with the
  summary region containing `*pending*`. Every later step replaces a region in an existing file;
  there is no "assemble from scratch" path to get wrong, and no failure mode where a completed
  transcript is invisible because summarization didn't happen.
- **Frontmatter is flat.** No nested `speakers: {…}` mapping: Obsidian's Properties system
  doesn't support nested objects and rewrites the whole block (flow→block, reordered, requoted)
  whenever any property is edited. Flat `key: value` parses with a five-line splitter — no YAML
  dependency, no hand-rolled parser.
- **Writes use `FileManager.replaceItemAt`**, not `Data.write(.atomic)`. The latter swaps the
  inode, dropping xattrs, Finder tags and file identity, and breaking open handles.
- Re-read from disk before every write; **fail loudly** if markers are missing — never append a
  duplicate region.
- **Speaker rename** anchors its replace to the line-leading `**[HH:MM:SS] <label>:** ` pattern
  (a naive `S1`→`Marie` also hits `S1` inside utterance text). Renaming onto an existing label is
  refused — that's a *merge*, which is a separate, explicit operation (F8) so it can't happen by
  typo. Frontmatter is the source of truth.
- Notes carry **no automatic timestamps**. *Revised during Phase 5: the original design
  stamped every line. Stamps went stale the moment a line was reworded, most notes are general
  observations a precise time misrepresents, and the claimed benefit to summary quality was
  never verified.* ⌘T inserts `[12:04] ` deliberately when a thought really is anchored.

**F7 — Notes live in `.plume/notes.md`, saved whole on a 1.2s debounce.** They are never
written into `meeting.md` during a call — that file doesn't exist yet, and writing there live
would race with anything the user has open in an editor. Once the transcript exists, the Notes
region is kept in step.

*Revised during Phase 5:* the original design appended one stamped line per entry, with a
`--- after the call ---` divider. Both are gone. Append-only fought editing; the divider was
structure leaking into the user's own words, and meant little once lines weren't individually
stamped. The cost — a crash can lose a second or two of typing instead of nothing — was
accepted deliberately.

**Pipeline state is explicit.** Quill's crash-resume sentinel is literally "`meta.json` exists
&& `transcript.json` missing" — which Phase 3 deletes. Replace with `stage:` in
`.plume/state.json`:

```
recorded → transcribed → summarized
       ↘ failed(stage, message) / needsPermission / cancelled
```

*Implemented with three durable stages, not the five originally sketched.* `diarized` never
becomes a distinct resting state — diarization failure degrades to `them` and continues — and
`awaiting_wrapup` **is** `transcribed` with no summary yet. Three stages that genuinely occur
beat five where two are decorative.

Failure states are explicit, not implied by absence: `failed` carries the stage and error so the
UI can offer a targeted retry, `needs_permission` is distinct from `failed` because the fix is
user action rather than a retry, and `cancelled` records a deliberate abandon so it isn't
endlessly re-offered. `resumePending` becomes a stage machine, and `.plume/` survives until the
last stage lands.

`awaiting_wrapup` can persist indefinitely by design — "transcribed but never summarized" is a
normal resting state, not an error (R10). Since `meeting.md` now exists from `diarized` onward,
every state past that point has a readable artifact on disk.

## What Quill gives us free [verified]

- **Core Audio process tap** — `CATapDescription` → `AudioHardwareCreateProcessTap` → private
  aggregate device with drift compensation → IOProc on a dedicated queue. The annoying part.
- **Crash-safe capture** — AAC-in-CAF streamed from tap callbacks; CAF needs no finalization.
- **Filesystem-as-queue** — crashes retry for free. Keep the idea, replace the sentinel.
- **Model lifecycle** — `prepare()`/`release()` with release on drain. Load-bearing at 16 GB.
- **Dual-track = free me/them separation** before any model runs.

## What we inherit that needs fixing

- `MicRecorder` is `@unchecked Sendable` to satisfy one `DispatchQueue.main.async`, disabling
  checking on genuinely racy state (`firstBufferAt`, `livenessFrames`, `file` written from the
  audio thread, read from main). Fix in Phase 1, before Phase 5 adds a second reader.
- `Transcript`, `Transcript.Segment`, `SessionMeta` are `private` file-scope types. Lift.
- Speaker identity is two string literals (`"me"`/`"them"`) in `SessionMeta.read`.
- `merged.sort` is not stable — equal-timestamp ordering is arbitrary.
- `statusHandler` is a single slot. Replace with `@Observable` in **Phase 1** — Phases 2–5 each
  add failure modes (Ollama down, model missing, diarizer download failed, tap gone silent) and
  all of them need somewhere to surface. It's ~30 lines.
- `Config.load()` re-parses JSON on every accessor call, including from inside an actor.
- No tests, no CI, no bundle, no signing. Stale comment at `MicRecorder.swift:8`.

## Upstream PRs worth harvesting

Quill has **14 open PRs and exactly one merged** (a README link fix). Community work is not
being taken upstream, which reinforces the fork decision — none of this arrives for free — but
several PRs are directly on our critical path and are worth cherry-picking. All are MIT by the
repo's terms; attribute them.

*Evidence below is the PR authors' own, credible but not independently reproduced by me. Each
is marked with what it would take to confirm.*

| PR | What it gives us | Why it matters here |
|---|---|---|
| **[#54](https://github.com/digimata/quill/pull/54)** | System audio is **all-zero silence unless quill runs as a LaunchAgent** | **Read before Phase 1.** See B3 below — this is a potential blocker on the `.app` decision. |
| **[#2](https://github.com/digimata/quill/pull/2)** | Mic capture dies when a call app reconfigures the input device; restart on `AVAudioEngineConfigurationChange` with a 0.5s debounce, re-attaching to the same open file and zero-padding the dead span to preserve wall-clock alignment | Reported repro: a 19-minute FaceTime call produced a **1.7-second** `mic.caf`. This is not an edge case, it's the core use case. Upgrades R6. |
| **[#25](https://github.com/digimata/quill/pull/25)** | Transcript-level echo filter: word-level LCS, ≥70% in-order containment, ±400 ms pad, 1–2 word segments only drop on exact match | Reported: **477 of 641 "me" segments** in a real 42-minute meeting were echoes of far-end speech, which reached the mic *louder* than the user's own voice. Resolves R9. |
| **[#20](https://github.com/digimata/quill/pull/20)** | Diarization via FluidAudio's offline Community-1/VBx, splitting turns at diarization boundaries using Parakeet word timestamps, with a **confidence threshold that falls back to `them`** rather than guessing | Independent arrival at the same architecture as F1/F6 — strong corroboration. The per-segment confidence gate is better than my all-or-nothing fallback. Reference implementation for Phase 2. |
| **[#6](https://github.com/digimata/quill/pull/6)** | Liveness watchdog: 15s timer polling `.caf` file sizes, 45s stall → notification, with recovery announcements | 54 lines, exactly R6's heartbeat. Cheap insurance given audio is deleted immediately. |
| **[#18](https://github.com/digimata/quill/pull/18)** | `OSAllocatedUnfairLock`-backed `LockedState` around the cross-thread `file` / `firstBufferAt` fields in both recorders | The concrete fix for the `@unchecked Sendable` debt. Also fixes a malformed inline SVG icon. |
| **[#7](https://github.com/digimata/quill/pull/7)** | Write the completion marker **last**, so a failed later write leaves the session pending | We replace the sentinel with a stage machine, but the ordering principle applies unchanged. |

Not needed: #52 (Whisper), #3 (AssemblyAI, cloud), #55/#4/#9 (Parakeet v3 / language selection —
English-only per F2), #53/#12 (release and notarization tooling — out of scope).

Note #16, #17 and #18 all fix the same data races, and #24/#25 are duplicate echo filters. Take
the most recent of each.

**B3 — System-audio capture depends on being its own responsible process, and fails silently.**
This is the finding that most threatens the plan. Per #54: launched from a shell,
`AudioHardwareCreateProcessTap` returns `noErr`, the format is correct, the aggregate device is
created, `AudioDeviceStart` succeeds, and the IO proc fires at exactly the right rate for the
whole session — and **every sample is zero**. TCC attributes the request to the *responsible*
process; from a terminal that's the terminal, so quill has no identity to grant and no prompt is
ever raised. Under launchd it is its own responsible process, the prompt appears, and capture
works. The author reports that binding the embedded Info.plist via signature is **not**
sufficient on its own.

An `.app` launched via LaunchServices *is* its own responsible process, so the bundle should be
correct — arguably more robust than the LaunchAgent. But "should be" is not good enough for a
failure mode this quiet, and it is the one thing that could invalidate the Phase 1 packaging
decision. **Verify first, before any other Phase 1 work.**

It also gives `doctor` a real job. There is no side-effect-free API to query system-audio TCC
state, so the only trustworthy check is empirical: play a short tone, capture two seconds, and
assert the buffer is not all zeros. Every other signal — return codes, formats, packet counts —
is confirmed to look healthy while producing silence.

## Phasing

**Phase 1 — Spikes first, then fork and foundations.**

Three spikes, all short, all gating decisions already made. **The first is a go/no-go:**
  - **Responsible-process spike (B3).** Build a throwaway `.app`, launch it from Finder, record
    two seconds of system audio while playing a tone, assert the samples aren't all zero. If an
    `.app` does not get its own TCC identity, the packaging decision reverts to a LaunchAgent and
    Phases 5–6 need a different window-owning strategy. **Nothing else is worth building until
    this is answered.**
  - **Panel spike** — 40 lines of AppKit: confirm F4's style mask accepts typed text with Zoom
    frontmost, and confirm B2 (screen-share exposure) with a QuickTime recording.
  - **`num_ctx` spike** — load `gemma4:latest` at 4096 and 16384, diff `ollama ps` SIZE. The
    KV-cache cost has a **10× spread** depending on whether Ollama trims sliding-window layers
    (~16 KB/token if SWA-aware, ~172 KB/token if not — the latter blows the budget at 8k).

Then: fork Quill → Plume; rename bundle ID, binary, config path, output dir. Real `.app` bundle
(build script from SPM output; `anthropic-skills:xcode-makefiles` covers it), `LSUIElement = true`,
`SMAppService.mainApp` for login. Lift the private types. Add a test target. Pin FluidAudio
`.exact("0.15.5")`. Swap `statusHandler` for `@Observable` + a menubar error item. Define the
final transcript segment shape **including `speaker` and word timings** so Phase 2 doesn't
rework it. Add the settings shell (F10): a `Settings` scene on ⌘,, plus the `Config` caching and
file-watch fix that a writable UI makes mandatory. Panes accrete per phase; it stays empty here
apart from recordings folder and launch-at-login.

Port from upstream PRs while the codebase is still small: **#18** (`OSAllocatedUnfairLock` around
the racy recorder fields), **#2** (mic restart on `AVAudioEngineConfigurationChange`), **#6**
(liveness watchdog). The last two are not polish — per #2, a call app taking the mic silently
kills capture, and with audio deleted immediately a half-recorded meeting is unrecoverable.

Give `doctor` the empirical system-audio check from B3 — tone in, assert non-zero — because every
other signal looks healthy while producing silence.

*Done when:* all three spikes have answers, and a menubar record from `/Applications` produces a
transcript with **verified non-zero** system audio.

**Phase 2 — Diarization and echo.** `OfflineDiarizerManager` over the system track only, with
F1's four config settings. Word-timing attribution and re-segmentation on speaker boundaries
(F6), cross-checked against **PR #20**, which reaches the same architecture independently — and
adopt its refinement: gate each attribution on an alignment-confidence threshold and fall back
to `them` per segment rather than guessing a speaker.
Port the echo filter from **PR #25** in this phase, not later: it is a merge-time pass over the
same segment data and shares the word-timing plumbing.
Note the manager is a `public final class` with `nonisolated(unsafe)` state — **not `Sendable`**
— so it needs an owning actor, not a protocol existential; this surfaces as a compile error on
day one. Avoid the name `Diarizer`: FluidAudio already declares that protocol.
*Done when:* against the held-aside test corpus (R3), a 3-person call yields distinct speakers
**and** a 1:1 yields exactly one remote speaker. The second is the one that will fail, and
because production audio is deleted immediately there is no second chance in the field.

**Phase 3 — Single-file markdown + stage machine.** `meeting.md` written at the `diarized` stage
with `## Summary` reading `*pending*`; marked regions, flat frontmatter, `replaceItemAt`,
`.plume/state.json` stage machine with the explicit failure states. Audio is deleted the moment
the transcript region has been written — but only then, so a crash before that point still resumes.
*Done when:* a recording produces one `meeting.md`, and killing the app mid-pipeline resumes
correctly from each stage.

**Phase 4 — Summaries.** `SummaryEngine` over Ollama's native `/api/chat`: `num_ctx: 32768`
(measured — Spike C), `truncate: false`, `shift: false`, 300s timeout for cold model start.
Single pass when the transcript fits; map-reduce over ~10-minute windows only when it doesn't.
Handle "Ollama daemon not running" as a first-run state, not an error — Ollama.app starts it
lazily. Templates as markdown files with
a seed-on-first-run step and an "Open Templates Folder" item (F9). Title and speaker-name
proposals via schema-constrained `format` output in the same reduce call, plus the folder rename
(F12). Settings pane: model picker from `/api/tags`, template default. Wrap
transcript and notes in explicit untrusted-input framing (anyone on a call can say "ignore
previous instructions"; OpenOats already does this).
Extend `doctor` to check Ollama reachability, version, and that the model is in `/api/tags`.
Treat `num_ctx` / `truncate` / `shift` as **integration-tested against the pinned Ollama version**,
not assumed — one test that sends an over-length prompt and asserts an error rather than a quietly
short answer. Keep the model configurable and try a smaller one (`gemma4:e4b`) as part of
acceptance: 9.6 GB on a 16 GB machine may work and may also swap.
Summarization is invoked, not automatic (F8) — at this phase drive it from a menubar item;
Phase 5 moves the trigger into the panel. `meeting.md` already exists by now (F8), so this stage
only replaces the summary region.

Three correctness details:
- **Stream to a buffer, replace on success only.** A partial or failed stream must never
  overwrite a previous good summary. Regeneration that fails leaves the old summary intact.
- **Carry context across map-reduce windows.** Independent 10-minute windows lose decisions made
  in one window and revisited in another. Each window gets a short running digest of prior
  windows, and window summaries retain timestamp anchors so the reduce step can attribute claims.
- **Only manage our own model.** Ollama is a shared daemon and another app may be using a
  resident model. Unload *Plume's* model after summarizing (`keep_alive: 0`); do not evict
  others. An aggressive-memory mode that does can exist, opt-in, for the 16 GB squeeze.
*Done when:* a 2-hour transcript summarizes with the **middle** represented, not just the ends.

**Phase 5 — The panel, both modes.** Per F4, F8 and the Phase 1 spike.
- *Collapsed:* a 62×22 borderless capsule showing the record dot and elapsed time.
- *During the call:* non-activating strip with a full notes editor, ⌘T to timestamp.
- *After stop:* expands and activates into Notes (focused) / Summary tabs; Summary shows
  transcription progress, then a Summarize action, streaming output, template picker,
  regenerate, and the speaker list with rename fields.
Appends to `.plume/notes.md` throughout.
*Done when:* you can type notes during a live Zoom call without Zoom losing frontmost status,
then stop, add two more lines, hit Summarize, and get a summary that reflects them.

**Phase 6 — History window.** Now smaller than originally scoped: the panel (Phase 5) already
handles everything about a *fresh* meeting, so this window is only for going back to older ones.
A list, and per-meeting: open in the system markdown editor, reveal in Finder, regenerate with a
different template, rename speaker. **No in-app text editing** — notes are markdown files, edited
in a real editor. It also surfaces any meeting still sitting in `awaiting_wrapup` (R10).
*Done when:* you can reopen last week's meeting, rename S1→"Marie", switch template, regenerate,
and see only the summary region and its frontmatter keys change.

**Phase 7 — Ask (optional).** One SwiftUI component — an input row pinned under the Summary view
— hosted in both the wrap-up panel and the history window (F11), with a "save answer to notes"
action that appends to the Notes region. Same client as Phase 4, with a non-zero `keep_alive`
during a session and an explicit unload on close. At `num_ctx: 32768` most meetings fit whole,
so Ask sends the full transcript by default and falls back to Phase 4's chunked retrieval only
when it doesn't — a 2-hour meeting is ~30k tokens and leaves no room for the exchange. Still no
embeddings; still one meeting at a time. First candidate to cut.

## Scope

**Decided:** no in-app markdown editor. It was the one item here that isn't a weekend's work,
and the least differentiated — the files are markdown in a folder and every Mac already has a
good editor. Phase 6 is *list, reveal in Finder, open in external editor, regenerate, rename
speaker*. The "edit my notes and regenerate" requirement is met; the editing happens in Obsidian
or iA Writer, and Plume owns the regeneration.

Also declined: the JSON template store (markdown files in a folder instead — F9), OpenOats'
meeting-family/history resolution (~200 lines), cross-meeting embeddings, and `speakerDatabase`
*acoustic* auto-naming (FluidAudio's `enrollSpeaker` exists only on the *streaming* diarizers, so
recognizing a voice across meetings would be DIY cosine matching, not a free API). Note F12's
name derivation is a different mechanism — it reads what was *said*, not how it sounded, so it
works within a single meeting with no voice profile at all.

## Risks

| | Risk | Mitigation |
|---|---|---|
| **R1** | **FluidAudio breaks APIs in patch releases** [verified: v0.14.4 broke LS-EEND constructors and reverted in the same release; `SpeakerManager` flipped actor→struct across two patches; v0.15.5 removed `DownloadUtils` as breaking; no CHANGELOG] | Pin `.exact("0.15.5")`. Wrap every call behind our own protocol. Treat bumps as compile + DER spot-check. `OfflineDiarizerManager`'s changes across 0.14–0.15 have been additive. |
| **R2** | **Diarization accuracy is the highest-variance component.** 10.6% DER is AMI-SDM (4 speakers, single distant mic) — a proxy, not a guarantee for VoIP | Per-segment confidence gate falls back to `them` rather than guessing (PR #20). Rename **and merge** are the human fixes. Test the 1:1 case explicitly (F1). |
| **R3** | **No audio means no re-runs.** Deleting immediately is a decided requirement, so a meeting with mislabelled speakers or a silent mic track is simply lost | Tuning happens against a **held-aside test corpus**: 3–4 recordings (a 1:1, a 3-person call, one on speakers) kept outside the pipeline, used to re-run diarization config. Makes Phase 2's acceptance criteria load-bearing. Strengthens R6 — a dead tap must be caught *live*. **Also: "deleted" is a retention policy, not secure erasure.** Audio may survive in Time Machine, APFS local snapshots, or a synced folder. If `~/Meetings` ever lands in iCloud Drive, `.plume/` must be excluded. |
| **R4** | **Consent and legal exposure.** Plume records other people with no notice or indicator. Recording a private conversation without participants' knowledge is a criminal offence in France (Code pénal art. 226-1) and in US two-party-consent states | Visible recording indicator; a one-line disclosure to paste into chat. Cheap now, awkward to retrofit. Verify for your own jurisdiction. |
| **R5** | ~~16 GB is tight.~~ **Largely defused for summarization** ([Spike C](../spikes/num-ctx/RESULTS.md)): KV is 552 MiB at 32768, so weights + cache ≈ 10.2 GB against a ~11.5 GB working set, generating at 33.6 tok/s. The remaining risk is *sequencing*, not context size | Release ASR and diarizer models before summarizing. Sequence: transcribe → diarize → `release()` → summarize → unload *our* model with `keep_alive: 0`. Do not evict other apps' models unless the opt-in aggressive mode is on. `OLLAMA_KV_CACHE_TYPE=q8_0` and `OLLAMA_FLASH_ATTENTION=1` are server env vars — document as setup, not app config. |
| **R14b** | **Audio present but too quiet to transcribe.** Found 2026-08-14 during the first real recording: macOS input volume at 29/100 produced speech peaking at −31 dBFS (~−49 dB loudest 1s RMS) — clearly speech, clearly too quiet. Every existing safety net checks for *absence* of audio (permissions, `doctor`, the #6 watchdog, Spike A's non-zero assertion); none catches a weak signal. With audio deleted immediately (R3), a whole meeting is transcribed badly and cannot be redone | Add a **level** check, not just a presence check: `doctor` samples the input for ~2s and warns below a peak threshold; the recording session tracks peak level and warns once, early, if the mic stays weak for the first 30s. Report level in dBFS, not a bar graph — the number is what makes it actionable |
| **R6** | **Mic capture dies when a call app takes the input device — the core use case, not an edge case.** PR #2 reports a 19-minute FaceTime call producing a **1.7-second** mic track, silently. Sleep/wake and AirPods switching are the same class | Port #2 (restart on `AVAudioEngineConfigurationChange`, 0.5s debounce, re-attach to the same file, zero-pad the dead span so timestamps stay wall-clock true) **and** #6 (15s size-poll watchdog, notify on a 45s stall). Also observe `NSWorkspace.willSleepNotification`. Both land in Phase 1. |
| **R7** | **First run downloads 486 MB lazily inside `prepare()`** — i.e. after the first meeting ends, on whatever network, with no progress UI in a menubar app | Pull models from `doctor` at first launch using FluidAudio's `progressHandler`. |
| **R8** | **Temp-disk surprise.** `makeDiskBackedSource` converts the whole file to 16 kHz mono float32 in `temporaryDirectory` before mmapping — ~460 MB for a 2-hour meeting, leaked if it crashes mid-diarization | Clean up on launch as well as on completion. |
| **R10** | **A human-gated summary is a summary that may never happen.** Close the laptop after a call and the meeting sits in `awaiting_wrapup` forever — the cost of F8's wrap-up gate | `meeting.md` already exists with a full transcript from the `diarized` stage onward, so nothing is ever *lost*, only un-summarized. Surface pending meetings in the menubar with a count, list them in Phase 6, and offer "summarize now" per meeting. Optionally auto-summarize on next launch for anything older than a day. Never block on the gate. |
| **R11** | **Wrap-up competes with the next meeting.** Back-to-back calls mean stopping one recording while the next is starting; a panel demanding attention is exactly wrong then | Starting a new recording must never block on an unfinished wrap-up. The panel switches to the new session; the previous meeting drops to `awaiting_wrapup` and is picked up from the pending list. |
| **R12** | **The system tap is global — it records notifications, music, and every other app.** Anything playing during a call becomes transcript input, and a Slack ding mid-sentence corrupts a segment | `CATapDescription` supports per-process and exclusion forms; Quill passes an empty exclusion list to get everything. Offer a "call audio only" mode that taps the meeting app's process, falling back to global. Test across headphones, speakers, Bluetooth, and mid-call device switches — the same matrix R6 needs. |
| **R13** | **Speaker IDs are only consistent within one diarization run.** If a recording is ever split into segments (sleep, an unrecoverable device change), `S1` in segment 1 is unrelated to `S1` in segment 2 | Keep the *system* track as a single file — R6's mic restart already re-attaches to the same open file rather than starting a new one, so the common case doesn't split. If a split is ever unavoidable, stitch with `DiarizationResult.speakerDatabase` embeddings (cosine match across segments) rather than trusting labels. |
| **R14** | **Auto-derived speaker names can be confidently wrong**, and a wrong name is worse than an honest `S1` — it attributes quotes to a real person who didn't say them, in a file you'll later trust | Proposals only, never applied automatically (F12). Show the evidence span alongside each proposal, propose nothing below a confidence floor, and require one click. Frontmatter records that a name was accepted rather than derived. |
| **R9** | ~~Echo suppression may be solving a solved problem.~~ **Resolved: it is a real and severe problem.** PR #25 measured **477 of 641 "me" segments** in a 42-minute meeting as echoes of far-end speech, which reached the mic *louder* than the author's own voice (−33.9 vs −37.6 dBFS) | Port #25's filter in Phase 2 — word-level LCS, ≥70% in-order containment, ±400 ms pad, exact-match-only for 1–2 word segments so backchannels survive. Log drop counts; never drop silently. |

## Verification

- **Unit:** marker-region read/replace including the missing-marker case; flat-frontmatter
  round-trip; word-timing↔speaker attribution on synthetic segments; chunking budget in
  characters *(note: OpenOats' equivalent does count characters — what's broken there is the
  remedy, which keeps head+tail thirds regardless of size)*; speaker-rename anchoring.
- **Diarization, on the R3 corpus.** Four questions, in priority order:
  1. **Does threshold 0.7 over-split a real 1:1?** Run `plume diarize` on a 1:1 far-end track
     with `expected_participants: 0` (uncapped). One speaker = the cap is belt-and-braces and
     *uncapped* should become the default. Two or more = the cap is load-bearing, and the
     current default is right. **This single measurement decides the default**, and it is the
     highest-value test outstanding — 1:1s are the modal meeting.
  2. **A 3-person call yields distinct speakers** with `expected_participants: 3`.
  3. **A group call with the default (2) degrades to `them` for everyone** — honest, not
     mislabelled. Confirms the failure mode of forgetting to change the setting.
  4. **Speaker numbering follows first appearance**, so `S1` is whoever spoke first.
- **Long meeting:** 2-hour transcript through Phase 4; confirm the middle is represented.
- **Crash resume:** kill the app after each stage; confirm it resumes and never re-runs a
  completed stage. Kill it during `awaiting_wrapup` and confirm the meeting reappears as
  pending with its notes intact.
- **Panel, during:** type notes in a live Zoom call — Zoom stays frontmost. Screen-share the
  desktop and confirm the panel is **absent** from the share (B2, corrected — `.none` works;
  verify against the actual conferencing app, not just QuickTime).
- **Panel, after:** stop recording, add wrap-up lines while transcription is still running,
  Summarize, and confirm the late lines are reflected in the output.
- **Back-to-back (R11):** start a second recording with the first still in wrap-up; neither
  meeting's notes may be lost or cross-contaminated.
- **Regeneration:** hand-edit Notes, regenerate, diff — only the summary region **and its
  frontmatter keys** (`summary_generated`, `model`, `template`) may change.
- **Failed regeneration preserves the old summary:** kill Ollama mid-stream; the previous
  summary must still be intact in the file.
- **Draft-before-summary (F8):** kill the app right after diarization; `meeting.md` must exist
  and be readable with `## Summary` reading *pending*.
- **Speaker merge:** force a split (a 1:1 diarized as S1/S2), merge them, and confirm both
  labels collapse in the transcript region and the frontmatter.
- **Name proposals (F12/R14):** a call where someone self-introduces should propose that name
  with evidence; a call where nobody is ever named should propose **nothing** rather than guess.
  No proposal may be applied without a click.
- **Folder rename (F12):** confirm the timestamp folder is renamed exactly once, before
  `meeting.md` is written, and that a failed titling leaves the timestamp name intact.
- **Templates (F9):** edit a shipped template, restart, confirm the edit survives; drop a new
  `.md` in the folder and confirm it appears in the picker.
- **Permissions:** clean `/Applications` install → `doctor` → confirm mic and system-audio
  prompts attribute to Plume and models land in `~/Library/Application Support/FluidAudio/Models/`.
- **System audio is actually non-zero (B3):** every release build, play a tone and assert
  captured samples aren't all zero. Return codes, stream formats and packet counts are all
  confirmed to look correct while producing pure silence — this is the only check that catches it.
- **Mic survives a call (R6):** record across a real FaceTime or Zoom connect *and* disconnect;
  the mic track must be full-length, not 1.7 seconds. Swap headphones for AirPods mid-call and
  confirm capture resumes.
- **Echo filter (R9):** ✅ *verified 2026-08-14 on a real recording* — 7 segments → 4, all three
  mic duplicates dropped. Still to check on the corpus: that genuine interjections **over**
  far-end speech survive, which the first recording had none of.
- **Echo filter meets diarization:** with the far end split into S1/S2, confirm echoes are still
  caught. Upstream's filter compared against the literal `"them"` and would have missed them;
  covered by a unit test, not yet by real audio.
- **Smoke test (2 min, replaces a former risk):** feed a real `system.caf` to
  `OfflineDiarizerManager.process(_ url:)`. It routes through `AVAudioFile` + `AVAudioConverter`
  and FluidAudio's docs list CAF explicitly, so this is expected to pass.

## Out of scope

Live transcription; cross-meeting search and embeddings; calendar integration; auto-detection;
cloud backends; multi-language ASR; speaker profiles across meetings; App Store distribution,
notarization, Sparkle.

## Minor corrections carried from review

`NSAppTransportSecurity`/`NSAllowsLocalNetworking` is **not** needed — ATS exempts loopback, and
OpenOats ships no such key while talking plain HTTP to Ollama. Use `127.0.0.1` (not a LAN
address) to stay inside macOS 15+ local-network-privacy's loopback exemption.
