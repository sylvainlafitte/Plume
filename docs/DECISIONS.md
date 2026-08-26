# Dead ends, and things decided but not built

Two things only, both append-only:

1. **Tried and rejected** — dead ends *with their evidence*, so they aren't retried.
2. **Decided, not built** — design calls already taken for work that hasn't started.

Anything that became a standing constraint lives in [AGENTS.md](../AGENTS.md) instead; anything
that shipped is in git history. This file replaced a running progress log and a
pre-implementation plan, both of which had become descriptions of a repo you can just read.

---

## Tried and rejected

| Date | Tried | Outcome |
|---|---|---|
| 2026-08-15 | **Adding a `show(expandedMode)` "fix" for a Summary-tab switch that was never broken** | A reported symptom (pressing Summarize didn't move to the Summary tab) got a workaround before it got a measurement. Instrumenting it showed observation working exactly as designed — `summarize()` set `detailTab`, the very next body ran with it. The workaround was removed and nothing replaced it |
| 2026-08-15 | **Guessing three times at a UI clipping bug instead of measuring it** | The pill was cropped; I blamed the safe area, then the window minimum height, then a frame-vs-content-rect mismatch, shipping a "fix" each time. One temporary diagnostic logging `frame`/`content`/`contentLayoutRect` found it immediately: layout rect height was **0**, because the titlebar exceeded the window height. **When a layout bug survives one plausible fix, log the geometry before trying a second** |
| 2026-08-15 | Assuming `com.apple.provenance` was blocking codesign | It is on every file macOS 14+ writes, is **not** removable (`xattr -c` reports success and leaves it), and codesign tolerates it. The real blockers were `com.apple.FinderInfo` and `com.apple.fileprovider.fpfs#P`, applied by iCloud because the repo is in `~/Documents` |
| 2026-08-14 | **Concluding that "a shell-launched binary records silence"** | Over-generalised from one measurement with an uncontrolled variable. The same binary later passed from the same shell (0% → 99.5% non-zero) once the *terminal* had acquired the grant. Correct statement: a bare binary has no TCC identity and inherits the responsible process's, so a shell run is inconclusive **in both directions**. The `.app` decision is unaffected — it is the only deterministic, self-owned grant — and the empirical check matters *more*, since launch context cannot predict capture health |
| 2026-08-14 | Using `ollama ps` SIZE to measure memory cost | Useless — reproducibly non-monotonic for identical weights (3.2 GB @ 4096, 9.5 GB @ 8192–16384, 3.3 GB @ 32768+). Whatever it reports, it is not weights + KV. Use `~/.ollama/logs/server.log` `llama_kv_cache:` lines instead; those are exact and linear. Also: `ollama ps` columns are `NAME ID SIZE UNIT PROC% GPU CONTEXT UNTIL` — `CONTEXT` is field 7, and it is the reliable confirmation that `num_ctx` was applied |
| 2026-08-14 | Trusting a "verified" tag on `sharingType = .none` that turned out to be a *citation*, not a measurement | Wrong on our target OS. The source was Apple DTS declining to **guarantee** capture exclusion — a statement about warranties, not about whether the mechanism functions. Measured working on macOS 26.5.1 (`spikes/panel/RESULTS.md`). **When a claim is tagged verified, check whether someone measured it or merely found someone asserting it** |
| 2026-08-14 | Reading `ls -l` permissions to diagnose an `EPERM` on files under `~/Documents` | Misleading — TCC blocks `open()` while leaving `stat()` working, so the file shows a normal `rw-r--r--` and looks like an ordinary permission bug. The distinguishing probe: `stat` succeeds, `cat` fails, `ls ~/Documents` fails, `/tmp` fine. Fix is System Settings → Privacy & Security → Files and Folders, not `chmod` |

---

## Decided, not built

### Ask

A question box over past meetings. Four calls already taken:

- **A new surface, not a third tab.** A tab is scoped to the selected meeting, and a global Ask
  has no selected meeting. Keep a per-meeting tab *and* add a global window over one engine,
  where per-meeting is the N=1 case.
- **Retrieval before context.** ~300 meetings of summaries do not fit in 32k, so something must
  choose. Start with date range, keyword scoring over title/summary/speaker names, and an
  explicit meeting picker. Measure what that misses **before** adding a vector index that then
  has to stay in sync with a folder people edit by hand.
- **Summaries by default, transcripts opt-in** — for cost *and* quality: transcripts are noisy
  and crowd out signal at the same token budget.
- **Answers must cite the meetings they used.** Otherwise the answer is unverifiable, and the
  folder-is-the-database premise means the user can always go read the source. Same principle as
  invariant 3.

### Verification still owed on diarization

Every multi-speaker path is unit-tested only. The 1:1 leg passed on real audio (2026-08-17): one
remote speaker at the default `expected_participants: 2`. Still unrecorded, and each needs other
people:

- a 3-person call — separated correctly at 3, and degrading to `them` rather than mislabelling at
  the default 2;
- one recorded on speakers, with genuine interjections *over* far-end speech — the echo filter's
  false-positive half;
- one where the far end is two people, confirming the echo filter still fires when the far end is
  `S1`/`S2` rather than `them`;
- a call where a device is connected *and* disconnected mid-recording — the mic track must come
  back full-length, not 1.7s.

Copy each `system.caf`/`mic.caf` somewhere outside `~/Meetings` **before** the audio is deleted;
that is the only way these stay re-runnable.

### Naming a meeting without summarising it

Auto-titling lives inside `SummaryEngine`, so it is the only path that ever writes `title:`. A
meeting you record and never summarise therefore falls back to its folder name in
`MeetingLibrary.entry`, and the Meetings list reads as a column of timestamps. Explored
2026-08-25; canvas:
<https://claude.ai/code/artifact/6725dc77-4a9c-43f4-bfa5-491d11143f79> (pages: Placements ·
Title treatments · Recording panel · Lean header).

Calls taken:

- **Two entry points, one control.** Name it during the call (recording panel) *and* after it
  (the shared `MeetingDetailView`, so wrap-up and Meetings get it together and cannot drift —
  the drift this pair has already had twice). The during-the-call one is the load-bearing half:
  it is the only one that helps a meeting you close and never reopen.
- **Both write `title:` + `title_source: user`.** Anything else is undone by the next
  Regenerate — invariant 3 applied to titles, the same reason `MeetingAdmin.rename` sets it. The
  recording panel's field commits at Stop, alongside `meta.json`.
- **Not a text field — a heading that takes a caret** (canvas C4, and C1–C3 for the rejected
  alternatives). A filled 6pt-radius field is Plume's *notes* chrome, a surface you type
  paragraphs into; borrowing it for a one-line name makes the header read as a form. Unnamed, the
  line shows the start time in placeholder grey — not a prompt but the title the meeting actually
  has right now, the same string the list falls back to. Once named, the timestamp is gone from
  the header entirely.
- **On the recording panel the name takes the header's empty middle** (R1–R2). Fixed cost there
  is ~130pt — window controls 30, participant menu 30, red dot + clock 54, plus gaps — leaving
  ~150pt at the 340pt floor, about 24 characters. It degrades the right way: the name truncates,
  the clock and the count never do.
- **Cap the name at ~46% of the header, not a fixed width** (R4). A share of the width means a
  drag gutter survives at every size and both grow on resize. This is the direct consequence of
  the name occupying what was the header's `Spacer()` drag handle.
- **Participant menu moves to the footer** (R3/R4), which buys back ~45pt and leaves a header of
  four things: controls, name, handle, clock. This *reverses* the placement argued in
  AGENTS.md §2 and in `ParticipantsMenu`'s doc comment ("in the header rather than the footer
  because it is not an action") — both must be rewritten in the same commit, or the file is
  lying. The counter-argument stands and is worth re-reading before committing: the menu's whole
  value is being noticed at minute one.
- **Add timestamp stops being a button; the stopwatch inserts the stamp** (R5). On hover the red
  dot is *replaced* by a plus in the same 8pt slot and the time takes a hairline underline —
  nothing reflows, so the header's one already-moving element stays still. ⌘T is unchanged and
  becomes the discoverable path, because at rest nothing says the clock is pressable. Two known
  costs, neither fatal: the feature loses its only visible mention, and hover briefly removes the
  red dot, the one element that says *recording*.

The trap to build around (R6): the header then holds **two press targets inside what used to be
one drag handle**. Neither may be a `Button` — a Button reads a drag as a click, which is exactly
why the collapsed pill is a plain view with a tap gesture and a drag gesture side by side, and the
drag must sit on the targets themselves rather than on an ancestor spanning them. **The one
exception is not optional:** in edit mode the name is a real `TextField` and a drag inside it must
select text, so the drag gesture belongs to the display state only and comes off while editing —
the same rule that keeps `isMovableByWindowBackground` off. Get it wrong and the symptom is the
familiar one: text that will not select, window that slides instead.

Still open: whether the inline title commits its folder move on Return/blur only (assumed yes —
never per keystroke), and what the keyboard-focus affordance is for a heading that only reveals
itself on hover.

**Risks found while writing this up, in the order they would hurt:**

1. **There is no `meeting.md` at Stop.** It is created by `TranscriptionCoordinator`, minutes
   later, and it stamps `("title", dir.lastPathComponent)` — the folder name. A name typed during
   the call therefore has nowhere to go at commit time and must ride in `.plume/meta.json`,
   exactly like the participant override, with the coordinator preferring it *and* writing
   `title_source: user` beside it. Get this wrong in the obvious way — write the title, forget the
   source key — and `SummaryEngine`'s `guard !isUserTitled` (SummaryEngine.swift:119) does not
   fire, so the first summary silently replaces the name the user typed. That is invariant 3
   failing in the exact shape invariant 3 exists to prevent.
2. **Renaming the folder races transcription.** `stopSession` enqueues the session URL
   immediately and the coordinator holds it for the whole job — `transcribe.log`, `state.json`,
   `meeting.md`, then deleting the audio. Moving the folder at Stop moves it under a running job.
   The rule has to be: a typed title writes the *title*, never the folder, until the pipeline is
   done. The same race arrives from the other end once the wrap-up panel can rename — today
   `MeetingAdmin.rename` is reachable only from Meetings, where the meeting is finished; inline
   editing in the shared view makes it reachable while `transcribing…`. Either block the commit
   until `transcribed` or defer the move.
3. **The frontmatter escape does not cover newlines.** `needsQuoting` handles `:`, `#` and edge
   whitespace, and `escaped` handles `\` and `"` — a *pasted* multi-line title would inject lines
   into the frontmatter block and can emit a stray `---`. Strip newlines and cap the length on
   commit (the slug also has to survive a 255-byte filename limit).
4. **⌘T and the stopwatch insert "at the caret", and there are now two carets.** With a focusable
   title in the panel, a stamp can land in the *title*. Wire the stamp to the notes buffer
   unconditionally, not to whatever has focus.
5. **⌥⌘R then type.** Notes must keep initial focus (`notesFocused = true` on appear). If the
   title takes it, the first thing said in the meeting is typed into the meeting's name.
6. **A clicky clock is a moving target that redraws every second.** The label widens at the hour
   rollover (`12:04` → `1:02:04`), so the hit area shifts under the pointer, and
   `MeetingPillView`'s comment records that reading the controller directly is what stopped a
   per-second flash — a hover state on the same label risks rebuilding the header on every tick.
   Measure before assuming. A mis-click also silently edits the notes, which are the user's
   (invariant 4).
7. **Two hover-only affordances mean nothing to VoiceOver or to the keyboard.** Neither the
   editable heading nor the pressable clock announces itself, and there is no Tab path to the
   title. ⌘T survives only as a key equivalent — `AppMenu` is an invisible menu whose only job is
   routing — so removing the button removes the feature's one visible mention anywhere in the app
   or the README.
8. **The Meetings list will not show the typed name until the transcript lands**, because
   `MeetingLibrary.entry` reads frontmatter and there is no `meeting.md` before then. Minutes,
   usually — but it is a window where the user typed a name and the list still shows a timestamp.
9. **More callers of a rename that can move a folder.** AGENTS.md's rule that callers must use
   the *returned* URL (two same-minute meetings share the `yyyy-MM-dd-HHmm` prefix, and
   `renameFolder` drops the `-2` suffix) now applies to a path that can fire mid-flight.
10. **An empty commit is not an error.** `MeetingAdmin.rename` throws on an empty title; an inline
    heading that is cleared and blurred must mean "no change", not a red error line in a panel.
