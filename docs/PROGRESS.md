# Progress

Living log of **what has actually happened**, and — the part that matters most across sessions —
what was tried and rejected, so nobody re-runs a dead end.

Sibling documents: [AGENTS.md](../AGENTS.md) is the source of truth for how things work *now*,
and the only one loaded into every session — when work here changes a constraint, update it **in
the same commit**. [PLAN.md](PLAN.md) is the pre-implementation design record, now mostly history;
[archive/](archive/) holds closed work.

**What goes where in this file:** *Current state* is the first thing a new session reads, so keep
it short and true. *Decisions* and *Tried and rejected* are append-only and are the reason this
file is worth its length — a dead end recorded with its evidence saves the next session from
re-running it. Anything that becomes a standing constraint graduates to AGENTS.md and leaves a
one-line pointer here.

---

## Current state

**Phase:** 1–6 built. 7 (Ask) next, and optional. The architecture-review pass closed 2026-08-16
— see "The refactor pass" below for what was done, what was declined, and the two gaps it left.
**Next action:** either Phase 7 (Ask — a third tab in `MeetingDetailView`), or close out the
carried debt below. **Before either: the refactor's UI paths have no automated coverage** —
summarize, regenerate-failure and speaker rename in both surfaces want one manual pass through
the `.app`. The R3 corpus is the higher-value item: it is the only thing standing
between Phase 2 and "done", and it decides a default for the modal meeting.

**What works end to end today** (144 tests): menubar record → two-track capture → Parakeet transcription →
offline diarization + echo filter → `meeting.md` with marked regions → audio deleted → floating
panel for notes → templated summary via Ollama → title derived and folder renamed → speaker
rename/merge, plus a Meetings window for going back to any of it — with rename, delete-to-Trash
and the backend status beside Summarise.

> ### ⚠️ Carried debt: Phase 2 is unverified on real multi-speaker audio
> Every diarization and echo path is covered by synthetic unit tests only; the one real
> recording had a single speaker. **Do not mark Phase 2 complete, and do not treat the
> `expected_participants` default as settled, until the corpus below is recorded.** The 1:1
> measurement in particular decides a default for the modal meeting. This survives phase
> transitions on purpose — see "Human-dependent, start early".

**Blocked on:** nothing for building; the corpus and a real-call test need other people.

---

## Phase checklist

Phases 1–6 are built. Per-phase detail moved to
[archive/PHASES.md](archive/PHASES.md) 2026-08-16; what remains open:

| Phase | Open |
|---|---|
| 1 — Fork and foundations | `SMAppService.mainApp` login item, deferred |
| 2 — Diarization and echo | **Verify on the R3 corpus.** Every multi-speaker path is unit-tested only. *Done when:* a 3-person call yields distinct speakers **and a 1:1 yields exactly one remote speaker** — the second is the one expected to fail |
| 3 — Markdown + stage machine | — |
| 4 — Summaries | — |
| 5 — The panel | Global hotkey (needs Carbon `RegisterEventHotKey`); the menubar item covers it today |
| 6 — History window | — |
| 7 — Ask (optional, first to cut) | A **third tab** in `MeetingDetailView`, so it lands in both surfaces for free (reversed from "row under Summary" — PLAN.md F11); whole transcript in context where it fits, Phase 4's chunking when it doesn't; save-answer-to-notes |

---

## Human-dependent, start early

- [ ] **Held-aside test corpus (R3).** Needs *real* meetings with real people, so it has a lead
      time no amount of coding compresses. Copy each `system.caf`/`mic.caf` somewhere outside
      `~/Meetings` before the audio is deleted. Each answers a specific question:

  - [ ] **A 1:1 — the highest-value recording.** Settles whether threshold 0.7 over-splits one
        voice: `plume diarize` it with `expected_participants: 0`. One speaker → drop the cap
        and leave the diarizer unconstrained by default. Two+ → the cap is load-bearing and the
        current default of 2 is correct. **This is the modal meeting; the default hinges on it.**
  - [ ] **A 3-person call** — does it separate speakers correctly at `expected_participants: 3`,
        and does it degrade to `them` (not mislabel) when left at the default 2?
  - [ ] **One recorded on speakers** — echo filter against genuine interjections *over* far-end
        speech. The 2026-08-14 recording proved echoes are dropped but contained no cross-talk,
        which is the half that could produce false positives.
  - [ ] **One where the far end is two people** — confirms the echo filter still fires when the
        far end is labelled S1/S2 rather than `them`. Unit-tested only so far.

- [ ] **Verify quill#2 across a real call** (connect *and* disconnect). The mic track must come
      back full-length, not 1.7s. Only reachable with an actual call; guards against losing a
      whole meeting.
- [ ] Decide the recording disclosure wording for calls (R4).

---

## The refactor pass (closed 2026-08-16)

A read-only architecture review proposed thirteen fixes; the review itself is in
[archive/REFACTOR.md](archive/REFACTOR.md). What matters afterwards is the shape of the
judgement, not the list:

**Done** — the summary model no longer frozen at launch (`SummaryEngine` holds no client);
invariant-1 write failures surfaced instead of `try?`'d; the two meeting surfaces' duplicated
model logic extracted (`MeetingContent`, `NotesAutosave`, `MeetingDetailModel`'s extension);
`TemplateStore` cached on file mtimes; one frontmatter splice; `summarize()` returns the renamed
session; `Speaker.isRemoteLabel` and `Transcript.sorted` shared with their tests. The constraints
each of these now carries are in AGENTS.md §4 — that is the durable record. 114 → 122 tests.

**Declined, with reasons worth keeping:**

- **One shared `SummaryEngine`** across both surfaces. It is an actor, so sharing it *serialises*
  them: summarizing from history while the panel is still generating would sit on "Loading the
  model…" with no sign it was queued. The race it fixes costs latency, not correctness. Needs the
  queued state in the UI first.
- **Status-driven transcript arrival** instead of the panel's 2 s poll. The poll is wasteful and
  outlives its session, but the harm it enabled — following the wrong meeting — was fixed more
  cheaply by returning the session URL from `summarize()`. Revisit if the poll shows in a profile.
- **Formatter reuse on the list path** (~28 ms per 300-meeting scan, measured), the `EchoFilter`
  re-tokenisation, and the `h:mm:ss` triplication: real, small, and worth doing only when a change
  already opens those files.

**Two carried gaps, both worth fixing before the thing they block:**

1. **The refactor's UI paths have no automated coverage.** Summarize, the regenerate-failure
   reload and speaker rename in both surfaces are model code no test reaches. One manual pass
   through the `.app` is the cheapest close.
2. **`Config.path` and `TemplateStore.directory` are fixed global paths**, so a test that
   exercises them writes the developer's real config or templates. That is why the two most
   valuable regression tests here — "a model changed in config is used by the next generation"
   and "an in-place template edit is picked up" — were not written. A test-injectable path
   unblocks both.

Also surfaced and *not* part of the refactor: PLAN R7 (first-run model download still happens
lazily in `ParakeetEngine.prepare()`, not from `doctor` with progress) and R8 (no launch-time
sweep of FluidAudio's temp files — `grep temporaryDirectory Sources/` is empty). Both are
pre-existing; they belong in the backlog.

---

## Backlog — raised, thought through, not built

Ideas with enough analysis attached that picking one up doesn't start from zero. Each says
what makes it non-trivial, because none of these are as small as they look.

- [x] **Rename and delete a meeting. Done 2026-08-15.** Both in `MeetingAdmin`, reachable from a
      row context menu and an ellipsis menu in the detail header. Rename writes the title *and*
      `title_source: user`, moves the folder to `<stamp>-<slug>`, and disambiguates a slug
      collision (`-2`) rather than merging into an existing folder; the `yyyy-MM-dd-HHmm` prefix
      is preserved because the list sorts on it and renamed sessions are located by matching it.
      Auto-titling now **skips any meeting carrying the marker** — invariant 3 applied to titles,
      without which the next Regenerate would silently undo the rename. Delete goes to the Trash
      via `FileManager.trashItem` behind a confirmation naming the meeting, and selects the
      neighbour rather than jumping to the top. 7 new tests. **Open in editor / Reveal in Finder
      moved into the same menu**: none of the four is why the window exists — reading and
      regenerating a summary are — so the header keeps the title and one `⋯` menu, and one
      builder backs both the header menu and the row context menu so they can't diverge.

- [x] **Show the summary model / Ollama status next to Summarize. Done 2026-08-15.** A caption
      in `summarizeBar`: the model name when it's installed and reachable, orange
      "Ollama isn't running" / "<model> not installed" when it isn't. Probed once per appearance
      via `.task`, not per keystroke. Lives in the shared `MeetingDetailView`, so the panel and
      the history window both got it. Turns a post-press error into a precondition — and a cold
      daemon is a normal first-run state, not a fault.

## Decisions made during implementation

Append here as you go. Format: date, what was decided, and **why** — especially if it differs
from PLAN.md, in which case update PLAN.md too and say so.

| Date | Decision | Why |
|---|---|---|
| 2026-08-14 | Scaffolding: git + upstream remote, AGENTS.md, this file, `spikes/`, `.gitignore` | Multi-agent work across sessions needs revert-ability and a durable memory outside any one session |
| 2026-08-14 | **`.app` bundle confirmed as the packaging approach** (PLAN.md Phase 1 stands) | Spike A measured it rather than assuming: LaunchServices makes the app its own TCC responsible process. quill#54 still reproduces exactly on macOS 26.5.1 |
| 2026-08-14 | Build script must `xattr -cr` the assembled `.app` before `codesign` | SwiftPM's build dir carries `com.apple.provenance`; codesign rejects it as "resource fork, Finder information, or similar detritus". Will recur in the real Phase 1 build |
| 2026-08-14 | First-run flow must tolerate a late permission grant | A grant made *during* a capture arrives too late for that capture. The app needs to re-run or re-prompt rather than report failure |
| 2026-08-14 | **Keep `sharingType = .none`, keep the hide hotkey, promise nothing** | Spike B showed `.none` genuinely excludes the panel from ScreenCaptureKit capture on macOS 26.5.1 — it is not the no-op the plan assumed. The hotkey stays as defence in depth for untested capture paths (Zoom/Teams/Meet/browser) and future regressions; UI copy still must not claim privacy, since Apple guarantees nothing |
| 2026-08-14 | **Fork verified end to end.** Plume.app records both tracks from `/Applications`: system −2.5 dBFS peak with audio playing, `-inf` when silent (correctly silent, not noise); mic captures speech | Confirms Spike A's result holds in the real app, not just the probe. Structure is now `PlumeKit` (all logic) + a one-line `plume` executable, so tests reach internals via `@testable` without making anything public |
| 2026-08-15 | **A menubar-only (`LSUIElement`) app still needs a main menu** | Standard editing commands route through the main menu's key equivalents. Without one, ⌘C/⌘V/⌘X/⌘A/⌘Z reach nothing and beep — while selection keeps working, which points the investigation at the wrong layer entirely. `AppMenu.install()` exists purely for that routing |
| 2026-08-15 | **Wrap-up is an ordinary window, not the floating panel.** Recording keeps `.nonactivatingPanel` + `.floating`; wrap-up is a third window at normal level | The reasons to float and not activate all expire at Stop — the call is over, so other apps are entitled to cover it. The deciding factor wasn't layering though: a `.nonactivatingPanel` can be **key while another app is active**, and key equivalents route through the *active* app's main menu, so ⌘C would reach nothing in the one window whose whole job is producing a summary you copy out. `styleMask` can't be mutated after init, so this had to be a separate window rather than a mode. The incoming window adopts the outgoing one's frame, so Stop doesn't teleport the panel |
| 2026-08-15 | ⌘-Tab support **declined for now** | Would require `NSApp.setActivationPolicy(.regular)` — accessory apps are absent from ⌘-Tab by rule, not by configuration — which means a Dock icon and a real menu bar. Not wanted. If it is ever revisited, the thing to verify first is whether the **recording panel still behaves non-activatingly** after the app has been `.regular`: if it starts stealing frontmost from a call, the entire panel design is void |
| 2026-08-15 | **`contentTintColor` does not colour a status item's template image.** The recording icon is a pre-tinted, non-template copy instead | Reported as "it goes from white to black", not red. A template image's rendering treatment wins over the tint, so the icon dropped from the menu bar's own foreground colour to black — on a dark menu bar that reads as the icon vanishing, which is the opposite of a recording indicator (R4). Idle stays a template so it still follows light/dark; recording bakes the red in and turns the flag off |
| 2026-08-15 | Panel windows are not movable by background; headers and the pill carry `WindowDragGesture()` | Movable-by-background makes every content drag move the window, silently breaking drag-to-select and turning a pill drag into a click. The pill also stopped being a `Button` for the same reason |
| 2026-08-16 | **The panel's anchor corner is chosen per expand and stored, replacing the fixed top-right rule** | Top-right was never load-bearing — the invariant is only that collapse and expand pivot on the *same* corner, or a round-trip drifts the pill by the size difference. Fixed at top-right, a pill parked in a bottom or left corner expanded straight off the screen. `PanelAnchor` now flips an axis only when the preferred corner would overflow the screen the pill is on (flip-on-need, so behaviour with room is unchanged), clamps as a backstop for the cases where no corner fits, and the result is **stored until the next expand**. Re-deriving it at collapse was tried on paper and rejected: after a bottom flip the window sits high, the re-derived corner reads "top", and the pill returns hundreds of points from where it left — `PanelAnchorTests` pins both the round-trip and that failure |
| 2026-08-16 | **`Vocabulary.md`: one global glossary, injected above the untrusted preamble** | Separates two problems that look like one. ASR mishearing cannot be fixed here — Parakeet has no hotword/biasing hook and the audio is deleted — so the glossary is *repair at summary time*: the model recognises "Kodi" as Cody and spells it correctly in the document you keep. Global, not per-meeting: the jargon that matters is stable across meetings and a per-meeting file is friction at the worst moment. It goes **before** `untrustedPreamble`, since that preamble declares everything below it un-obeyable — right for a recording, wrong for a file the user wrote — and it is scoped to spelling/identification with an explicit "a term appearing here is never evidence that it came up", so it cannot smuggle content into a summary. Reaches `single`, `reduce`, `identity` **and** `window` (short and static, unlike the notes, and the window pass is where an unplaceable term gets dropped). The seed is entirely HTML comments so an unedited file contributes nothing — `strippingComments` is what enforces that, tests included. Rejected: rewriting the transcript from the glossary — a bad fuzzy match would be silent and unrecoverable |
| 2026-08-16 | **Notes guidance strengthened beyond the conflict rule, and it lives in `Prompt`, not the templates** | The single instruction ("where they conflict with the transcript, prefer the notes") fired only on contradiction, so a model that found none had nothing left to follow and could legitimately ignore the notes. Now four rules: conflict, *spelling* of names/jargon (ASR renders unfamiliar words phonetically, the attendee doesn't), notes-only content is real content and must survive, and what someone stopped to type is a weighting signal — closed with an explicit "none of this licenses invention" so it cannot fight the templates' no-invention rule. Kept in `Prompt` because it reaches every summary including hand-written templates, whereas `seedIfNeeded` never overwrites an existing file, so a seed edit reaches only installs that have never run. **Still open:** `Prompt.window` does not see the notes, so the compression stage that decides what to discard is blind to what the attendee cared about — a real gap, but fixing it spends context in every window and wants measuring first |
| 2026-08-16 | **Check the installed binary's timestamp before trusting a UI repro.** The first report that the new anchoring "still goes top-right" was a stale `/Applications/Plume.app` — the panel change had never been built into it | Costly failure mode, because a stale bundle reproduces the *old* bug perfectly and every explanation you invent for it is plausible. `ls -la /Applications/Plume.app/Contents/MacOS/plume` against the last commit time settles it in one command, and is now the first step before instrumenting any panel behaviour. The temporary `os_log` tracing added to diagnose it was removed once the rebuild confirmed the fix |
| 2026-08-16 | **Removed the "N without a summary" counters** (menu bar idle label, Meetings footer) and the `transcript ready` notification | Both told you something the surface you were already looking at was showing. The counters also cost a background rescan of every meeting folder on each history open, panel finish and stop — `AppState.pendingCount` and `AppController.refreshPending()` are gone with them. The per-row `no summary` capsule stays: it is per-meeting, which the counters were not. Failure notifications all stay — those fire when nothing on screen would tell you |
| 2026-08-15 | The recording panel calls `makeKey()` without `NSApp.activate` | `@FocusState` can only focus something in the key window, so the notes field could never take focus on appear. A non-activating panel can hold key while the call stays frontmost — that is what utility panels are for |
| 2026-08-15 | **Ask will be a third tab, not a row under the summary** (reverses PLAN.md F11) | F11's objection to a tab was that it would live only in the post-call panel and so be in the wrong place for old meetings. Sharing `MeetingDetailView` between the panel and history dissolved that — a tab now appears in both. A tab is also the right shape: Ask is a mode you stay in, not a control you press once. And it leaves the bottom edge to the summarize bar rather than two controls competing |
| 2026-08-15 | **Summarize pinned below the tabs; each surface picks its own opening tab** | Inside the Notes tab, the default tab decided whether the action was reachable at all. Pinned below, it is always available, so the default can just follow purpose: panel = writing (Notes), history = reading (Summary). Fixed per surface, never per meeting — a per-meeting default would make the tab jump as you scroll the list |
| 2026-08-15 | **The pill is a separate `.borderless` window; expanded states stay `.titled`** | `.titled` is required to become key (so you can type while a call stays frontmost) but carries an invisible ~28pt titlebar. Below that height `contentLayoutRect` collapses to zero and SwiftUI lays content out below the visible window. Anything shorter than a titlebar needs its own window |
| 2026-08-15 | Notes are free text with manual ⌘T timestamps; no auto-stamping, no wrap-up divider | Stamps went stale on edit, most notes aren't anchored to a moment, and the claimed summary-quality benefit was never verified. Cost: whole-file debounced saves lose ~1s of typing on a crash instead of nothing — accepted |
| 2026-08-15 | Summarize is the primary CTA under **Notes**, not on the Summary tab | Notes are the input, the summary is the output; the action belongs where you finish working, and editing-then-regenerating no longer means switching tabs. Summary tab is a result view |
| 2026-08-15 | `build-app.sh` stages and signs in `/tmp`, outside the repo | The repo is under `~/Documents`, which iCloud's file provider stamps with `com.apple.FinderInfo`/`com.apple.fileprovider.*` — what codesign actually rejects. Stripping them loses a race with the provider |
| 2026-08-15 | Region headings are de-duplicated when writing a region | The first real summary came out with `## Summary` twice: the region carries the heading, and the template also tells the model to emit it. Stripping on write keeps templates readable standalone and tolerates user-written ones — the same wart noted in OpenOats, reproduced and then fixed |
| 2026-08-15 | **Ad-hoc signing was why permissions reset on every rebuild.** Switched `build-app.sh` to the existing Apple Development identity | An ad-hoc signature's Designated Requirement is the cdhash, which changes with every build, so macOS saw each rebuild as a new app. A certificate-backed DR keys on cert + bundle ID and survives. `PLUME_SIGN_ID=-` forces ad-hoc if needed |
| 2026-08-15 | `RecordingSession` is now `@MainActor` rather than carrying an unchecked capture | The watchdog timer's `@Sendable` block captured a non-Sendable `self`. The class is *already* main-isolated in practice (only `AppController` touches it; the timer fires on the main run loop), so declaring it makes the class implicitly Sendable — stating the truth instead of asserting past it. Audio threads live a level down in the recorders, which own their own locks |
| 2026-08-15 | Silent far-end track logs "no speech", not "diarization failed" | `OfflineDiarizationError.noSpeechDetected` is the normal result for a headphones meeting or a call nobody has joined. Zero turns is the honest answer; the old wording put an alarming line in the log for a healthy run |
| 2026-08-14 | Documented all three `@unchecked Sendable` uses; `MicRecorder`'s is inherited debt, not justified | Writing "there is exactly one" in AGENTS.md and then grepping found three. quill#18 locked the racing *fields* but left the class-level conformance, so the debt is partially discharged, not removed — and the file claimed otherwise. Removing it is open work |
| 2026-08-14 | **`expected_participants`, default 2, caps far-end speakers** instead of retuning the threshold | 1:1s are the modal meeting, and threshold 0.7 is tuned on 4-speaker AMI material with a deliberate anti-merge bias — its characteristic error on a two-person call is splitting one voice. Lowering the threshold would trade that against under-splitting group calls, which is the *worse* error (conflating two real people is unrecoverable; over-splitting is one merge click). The speaker cap avoids the trade: N participants ⇒ N−1 far-end speakers, a number known in advance. **Open:** whether 0.7 actually over-splits a real 1:1 — if not, uncapped becomes the better default |
| 2026-08-14 | **Phase 2 verified on the echoed recording: 7 → 4 segments, all 3 mic duplicates dropped, no genuine speech lost.** Diarizer found 1 speaker and correctly kept `them` rather than inventing `S1` | End-to-end proof of the diarize → attribute → echo-filter chain. Note the multi-speaker path is still only covered by unit tests |
| 2026-08-14 | **quill#25 needed the same kind of fix as #2/#18: it hardcodes the far-end speaker as `"them"`**, which was right before diarization and wrong after — S1/S2 echoes would have passed straight through | Generalised to "any non-mic speaker". Second instance of upstream PRs being mutually unaware; assume it for every remaining cherry-pick |
| 2026-08-14 | **Merging quill#2 into quill#18 required a fix neither PR had.** #2 adds `lastBufferAt`, written from the tap thread and read on main; #18 is the PR that exists to lock exactly that class of state. Written independently, so upstream's #2 reintroduces the race #18 removes | `lastBufferAt` now lives inside `LockedState` alongside `file` and `firstBufferAt`. Worth remembering when taking further upstream PRs: they are mutually unaware, and combining two correct patches can still yield a broken result |
| 2026-08-14 | **Echo reproduced on our own hardware, first try** — 3 of 7 segments in a speaker-playback recording were mic-side duplicates of system audio. Independently confirms PR #25's 477/641 finding | Phase 2's echo filter is not speculative. Crucially the duplicate pairs are *not identical* — "chatbot"/"chat bot", "Kodi"/"Cody", "trading files"/"creating files" — so string equality cannot work; #25's word-level LCS with a ≥70% containment threshold is the right shape |
| 2026-08-14 | **This dev machine has a warm FluidAudio cache, so it cannot test cold start** (R7). Plume is intended for several machines, so first-run download is a real path, not a one-off | Test it deliberately: move `~/Library/Application Support/FluidAudio/Models/` aside and launch fresh. Models must be pulled from `doctor` at first launch with progress, never lazily after the first meeting ends |
| 2026-08-14 | Parakeet transcribes acceptably even at −31 dBFS, and emits nothing from a silent track | Low mic gain degrades but does not break ASR, and silence produces no spurious segments. R14b's level warning is still worth having, but it's a quality issue rather than a total loss |
| 2026-08-14 | **`doctor` and the session need a mic *level* check, not just presence** (R14b) | Real recording came back at 29/100 input volume → speech peaking −31 dBFS. Every existing guard detects *absent* audio; none detects *weak* audio, and R3 means there's no second take |
| 2026-08-14 | First-run mic offset is ~1.5s, steady-state ~250ms | The TCC permission dialog delays the mic engine on first launch; `start_offset_ms` records it correctly either way. Not a bug — but don't use a first run to judge track alignment |
| 2026-08-14 | **`num_ctx: 32768`, single-pass summarization by default** | Spike C measured KV at 16 KiB/token (552 MiB at 32768) rather than the feared 172 KiB/token. A 1-hour meeting fits in one pass, so map-reduce becomes the >2.5h fallback instead of the default — removing cross-window context loss for the common case |
| 2026-08-14 | `doctor` must treat "Ollama not reachable" as a normal first-run state | Ollama.app starts the daemon lazily; a cold `curl 127.0.0.1:11434` fails until something wakes it. Needs a remedy message, not an error |
| 2026-08-14 | Panel needs no `canBecomeKey` override | `.titled` + `.nonactivatingPanel` gives key-window status while leaving the other app frontmost. Confirmed with a SwiftUI `TextField`, the combination most likely to fail |

## Tried and rejected

The most valuable section. Record dead ends **with the evidence**, so they aren't retried.

| Date | Tried | Outcome |
|---|---|---|
| 2026-08-15 | **Adding a `show(expandedMode)` "fix" for a Summary-tab switch that was never broken** | A reported symptom (pressing Summarize didn't move to the Summary tab) got a workaround before it got a measurement. Instrumenting it showed observation working exactly as designed — `summarize()` set `detailTab`, the very next body ran with it. The workaround was removed and nothing replaced it. **Second time this session that measuring first would have been cheaper**; the rule is in AGENTS.md §5 for a reason |
| 2026-08-15 | **Guessing three times at a UI clipping bug instead of measuring it** | The pill was cropped; I blamed the safe area, then the window minimum height, then a frame-vs-content-rect mismatch, shipping a "fix" each time. One temporary diagnostic logging `frame`/`content`/`contentLayoutRect` found it immediately: layout rect height was **0**, because the titlebar exceeded the window height. **Lesson: when a layout bug survives one plausible fix, log the geometry before trying a second.** The earlier fixes were kept only where independently correct |
| 2026-08-15 | Assuming `com.apple.provenance` was blocking codesign | It is on every file macOS 14+ writes, is **not** removable (`xattr -c` reports success and leaves it), and codesign tolerates it. The real blockers were `com.apple.FinderInfo` and `com.apple.fileprovider.fpfs#P`, applied by iCloud because the repo is in `~/Documents` |
| 2026-08-14 | **Concluding from Spike A that "a shell-launched binary records silence"** | Over-generalised from one measurement with an uncontrolled variable. The same binary later passed from the same shell (0% → 99.5% non-zero) once the *terminal* had acquired the grant. Correct statement: a bare binary has no TCC identity and inherits the responsible process's, so a shell run is inconclusive **in both directions**. The `.app` decision is unaffected — it's the only deterministic, self-owned grant — and the empirical check matters *more*, since launch context can't predict capture health. Same error class as the PLAN.md B2 `[verified]` tag: a real observation stated as a law |
| 2026-08-14 | Using `ollama ps` SIZE to measure memory cost | Useless — reproducibly non-monotonic for identical weights (3.2 GB @ 4096, 9.5 GB @ 8192–16384, 3.3 GB @ 32768+). Whatever it reports, it is not weights + KV. Use `~/.ollama/logs/server.log` `llama_kv_cache:` lines instead; those are exact and linear. Also: `ollama ps` columns are `NAME ID SIZE UNIT PROC% GPU CONTEXT UNTIL` — `CONTEXT` is field 7, and it's the reliable confirmation that `num_ctx` was applied |
| 2026-08-14 | Trusting a `[verified]` tag in PLAN.md that turned out to be a *citation*, not a measurement (B2, `sharingType = .none`) | Wrong on our target OS. The source was Apple DTS declining to **guarantee** capture exclusion — a statement about warranties, not about whether the mechanism functions. Spike B measured it working on macOS 26.5.1. **Lesson: when a plan claim is tagged verified, check whether someone measured it or merely found someone asserting it.** Several remaining tags are citations |
| 2026-08-14 | Reading `ls -l` permissions to diagnose an `EPERM` on files under `~/Documents` | Misleading — TCC blocks `open()` while leaving `stat()` working, so the file shows a normal `rw-r--r--` and looks like an ordinary permission bug. The distinguishing probe is: `stat` succeeds, `cat` fails, `ls ~/Documents` fails, `/tmp` fine. Fix is System Settings → Privacy & Security → Files and Folders, not `chmod` |
