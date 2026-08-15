# Working on Plume

Local-only macOS meeting recorder → transcript → AI summary. Menubar app, no cloud.
Forked from [digimata/quill](https://github.com/digimata/quill) (MIT).

> **This file carries what you cannot infer from the code**: things that are irreversible if you
> get them wrong, decisions that look like omissions, and platform traps that fail silently.
> It is ordered by what a change is likely to cost, not by topic.

**Precedence:** the **code** wins over this file (if they disagree, fix the file in the same
commit). This file wins over **[docs/PLAN.md](docs/PLAN.md)**, which is a pre-implementation
design record — read it for *why*, not for *what is*.
**[docs/PROGRESS.md](docs/PROGRESS.md)** is the log: state, next action, and dead ends.

## 1. Invariants — breaking these destroys something unrecoverable

Audio is deleted after transcription, so most damage here cannot be undone.

1. **Never silently rewrite a marked region.** `meeting.md` has `<!-- plume:notes -->`,
   `<!-- plume:summary -->`, `<!-- plume:transcript -->`. Re-read from disk before every write,
   replace only between markers, and **fail loudly if a marker is missing** — never append a
   duplicate. Writes go through `FileManager.replaceItemAt`, never `Data.write(.atomic)`, which
   swaps the inode and drops xattrs and Finder tags.
2. **A failed generation must never destroy a good one.** Stream into a buffer; replace the
   region only on success.
3. **Derived names are proposals, not facts.** Inferred speaker names wait for one human click
   in `.plume/proposals.json`. A wrong name puts words in a real person's mouth — worse than an
   honest `S1`.
4. **The user's Notes are theirs.** Nothing reformats them: no imposed bullets, no automatic
   timestamps, no structural markers.
5. **Capture health is only knowable empirically.** A tap without permission returns `noErr`,
   reports a correct 48 kHz stereo format, creates its aggregate device, and fires its IOProc at
   exactly the right rate — with every sample zero. Play a tone, capture, assert non-zero.
   Nothing cheaper is true.
6. **Audio is deleted immediately after transcription, by decision.** Tune against the
   held-aside corpus, never against a real meeting.

## 2. Deliberate, not missing

These look like gaps. They are choices, most of them argued about and some of them reversals of
an earlier design. **Don't "fix" them without asking.**

| Looks like | Actually |
|---|---|
| No transcript view in the app | Deliberate. The transcript is summarizer input and text in `meeting.md`. Speaker rows show sample lines so you can identify a voice without one. |
| Notes have no automatic timestamps | Reversed in Phase 5: stamps went stale whenever a line was edited, and most notes aren't anchored to a moment. ⌘T inserts one on purpose. |
| Summarizing is manual | The wrap-up gate is the point — you add final thoughts *then* summarize. A meeting resting at `transcribed` forever is normal. |
| Only three templates, no template editor | Templates are markdown files in a folder; editing one means opening it. A JSON store and an editor UI were both declined. |
| No in-app markdown editor | Declined. The files are markdown in a folder and every Mac has a good editor. |
| Speaker names aren't applied automatically | Invariant 3. |
| Audio vanishes after transcription | Invariant 6, a requirement not a bug. |
| The panel opens on Notes but Meetings opens on Summary | Deliberate, not an inconsistency. The panel is where you *write* a record; the window is where you *read* one. Fixed per surface, never per meeting — a default that varied with the selection would make the tab jump as you scroll the list. |
| Summarize sits below the tabs, not inside Notes | So the default tab isn't load-bearing: the action stays reachable from either tab. It also leaves the bottom edge free for Phase 7's Ask tab. |
| `expected_participants` defaults to 2 | 1:1 is the modal meeting; the cap makes over-splitting one voice structurally impossible. Fix a mis-split with this, **never** by lowering the diarizer threshold. |

Genuinely **not built yet** (different thing): `SMAppService` login item, a Carbon global
hotkey, Phase 7 Ask — which will be a third tab in `MeetingDetailView`, not a row.

## 3. Build & run

```bash
swift build && swift test                      # library + 107 tests
./build-app.sh release run                     # assemble, sign, install, launch
./.build/debug/plume doctor                    # checks — but see below
./.build/debug/plume diarize <file.caf>        # dev: print diarizer turns
./.build/debug/plume summarize <session-dir>   # dev: summarize in place
```

**Never test audio capture with `swift run`; the result is meaningless either way.** A bare
binary has no TCC identity — capture is attributed to the *responsible process*, i.e. your
terminal. Without that grant you get full-length silence with no error; with it, capture works
while proving nothing about the app. Both were observed hours apart from one binary. Only the
`.app` has a self-owned grant.

**`build-app.sh` stages in `/tmp` on purpose.** This repo is under `~/Documents`, which iCloud
stamps with `com.apple.FinderInfo` — what codesign rejects as *"resource fork, Finder
information, or similar detritus"*. Stripping it loses a race with the file provider.
(`com.apple.provenance` is on everything, is **not** removable, and codesign tolerates it —
not the culprit.) Signing uses the Apple Development identity; ad-hoc keys its Designated
Requirement to the cdhash, so every rebuild would re-prompt for permissions.

## 4. Constraints that will cost you time

Each has fuller reasoning in a comment at the point of use.

**FluidAudio is pinned `.exact("0.15.5")`. Do not bump it.** It has made source-breaking changes
in *patch* releases — LS-EEND constructors broken and reverted inside one release,
`SpeakerManager` flipped actor↔struct across two, `DownloadUtils` removed in a patch. No
CHANGELOG. A bump means recompiling *and* re-running the corpus to compare DER. All calls sit
behind our own protocol so it stays a one-file diff.

**Use `OfflineDiarizerManager`, not `LSEENDDiarizer`** — half the error rate on meeting audio,
no speaker cap. Its settings are measured values, not preferences; see `DiarizationEngine.swift`.

**Parakeet stays on `.v2`.** `.v3` is FluidAudio's default, so omitting `version:` silently
changes the model.

**Ollama: native `/api/chat`, never `/v1`.** `/v1` has no `options` passthrough, so `num_ctx`
is unsettable and the context silently falls back to 4096 — summarizing only the tail of a
meeting. Send `num_ctx: 32768`, `truncate: false`, `shift: false`; the 400 you get on overflow
carries the token counts that size the map-reduce fallback. Use `127.0.0.1`. Unload *our* model
only — Ollama is shared.

**The panel is two windows and must stay that way.** `.titled` is needed to become key so you
can type while a call stays frontmost, but it carries an invisible ~28pt titlebar: below that
height `contentLayoutRect` collapses to **zero** and SwiftUI lays content out below the visible
window. Hence the 22pt pill is `.borderless`. Also: `hosting.sizingOptions = []`, or SwiftUI's
intrinsic size snaps the window back after every resize; and never mutate `styleMask` after
init — typing silently stops working.

**The wrap-up panel and the history window share `MeetingDetailView`.** They are the same
object at different ages — notes, summary, speakers, regenerate — so changes belong in the
shared view, not in one surface. They drifted within a single phase before it existed (only one
rendered markdown, only one had notes). Each supplies its own chrome and its own `initialTab`:
the panel opens on Notes because you are writing, history on Summary because you are reading.

**Swift 6 strict concurrency is on.** `OfflineDiarizerManager` isn't `Sendable` and needs an
owning actor. Don't reach for `@unchecked Sendable`: use a lock. The three that exist each carry
a justification, and `MicRecorder`'s is **inherited debt** — Quill disabled checking on the whole
class; quill#18 locked the fields that raced but the conformance still hides anything new.

**Pipeline state** is `.plume/state.json`: `recorded → transcribed → summarized`, plus
`failed(stage,message)` / `needsPermission` / `cancelled`. Only transcription resumes
automatically, and blocking must preserve the stage reached — otherwise a meeting whose audio is
gone gets re-transcribed into nothing.

## 5. Working habits

`Sources/PlumeKit/` holds everything (`Audio`, `Transcription`, `Meeting`, `Summary`, `UI`);
`Sources/plume/main.swift` is a one-line shim so tests can `@testable import`. `spikes/` is
committed on purpose — each has a RESULTS.md and re-runs.

`upstream` points at digimata/quill; we cherry-pick from its open PRs and **attribute them in
the commit message**. Upstream merges almost nothing, so don't expect to pull. Note the PRs are
mutually unaware: combining two correct ones has twice produced a bug.

Match Quill's voice — small files, comments explaining *why* a non-obvious thing is done. No new
dependencies without a note in PROGRESS.md saying what they replaced.

**When a bug survives one plausible fix, stop guessing and measure.** Three "fixes" went into a
clipped panel before one diagnostic printed the geometry and found it in seconds.

## Keeping this file current

*Last reviewed against the code: 2026-08-15, after Phase 6.*

**Update it in the same commit as the change, never "later."** A separate documentation pass
does not happen, and a silently wrong constraint is worse than a missing one — the next agent
will trust it.

**The test for belonging here** is not length, it's: *would getting this wrong cost more than
reading it?* Irreversible damage and reversed decisions always qualify. A platform trap qualifies
while it stays invisible — once a test or an obvious code comment enforces it, cut it here and
keep the pointer. Design rationale belongs in PLAN.md; status and dead ends in PROGRESS.md;
anything derivable from reading the code belongs nowhere.

Bump the date when you edit. If it is far behind HEAD, spend five minutes checking sections 1
and 4 against reality before trusting them.
