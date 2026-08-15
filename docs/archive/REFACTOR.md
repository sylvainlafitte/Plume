# Plume — architecture review and refactoring proposal

Read-only review of `Sources/PlumeKit` (3.9k lines) and `Tests/PlumeKitTests` (1.2k lines) at
`ddf677b`. Baseline confirmed green: `swift build && swift test` → 114 tests, 20 suites, passing.
**No code has been changed.** Everything below is a proposal.

---

## 0. Checked against AGENTS.md, PLAN.md and PROGRESS.md

A second pass over the three design records after the findings were written. Four outcomes:

**One proposed fix was wrong and has been replaced.** P2's original form — making
`OllamaClient.model` a computed property — would have broken *"Unload **our** model only — Ollama is
shared"* (AGENTS.md §4, PLAN R5). `summarize()` calls `stream()` and then, minutes later,
`unload()`; re-resolving between the two lets a config change mid-generation evict a model Plume
never loaded. The fix is now per-*operation* resolution. Details in §4.1.

**One finding was missing, and the documents are what surfaced it.** PROGRESS.md records that
renamed sessions are deliberately located by matching the `yyyy-MM-dd-HHmm` prefix — and
`RecordingSession` disambiguates same-minute collisions with a `-2` suffix, which that prefix match
cannot distinguish. R11 (back-to-back calls) is exactly the case that produces it. New finding
**P13**, and it changes P9's fix from "share the constant" to "delete the lookup".

**Three constraints now guard the Stage 1 extraction** that I would otherwise have had to
rediscover: the `flushNotes()`-before-session-switch ordering that R11 depends on; the explicit
record that `openInEditor`/`revealInFinder` must *not* act on the selection; and the per-surface
`initialTab`. All three are called out at the point they could be broken.

**Two documented mitigations appear not to be implemented.** Both are pre-existing and outside this
refactor — flagged in §6 in case they are news rather than known debt.

Nothing in the three documents contradicts P1, P4, P5, P6, P7, P10, P11 or P12. Several passages
support them, and one — PROGRESS.md on the Ollama status caption being *"probed once per appearance
via `.task`, not per keystroke"* — is direct evidence that the per-keystroke cost in P4 was already
a concern in that exact view.

---

## 1. Architecture

### Shape

One SwiftPM package. All logic lives in the `PlumeKit` library; `Sources/plume/main.swift` is a
five-line shim so the test target can `@testable import` without depending on an `@main` target.
Five domains under `PlumeKit/`: `Audio`, `Transcription`, `Meeting`, `Summary`, `UI`, plus
`App`/`AppState`/`Config`/`Doctor` at the root.

### Concurrency model

Three isolation domains, chosen per layer rather than uniformly:

| Domain | Members | Why |
|---|---|---|
| `@MainActor` | `AppController`, `AppState`, all UI, `RecordingSession` | State transitions and AppKit |
| Actors | `TranscriptionCoordinator`, `ParakeetEngine`, `OfflineDiarizer`, `SummaryEngine` | Own non-`Sendable` model managers; serialise long work |
| Locked shared state | `MicRecorder`, `SystemAudioRecorder` | Real-time audio callbacks — `OSAllocatedUnfairLock`, not actors |

`RecordingSession` being `@MainActor` is a good call: it makes the class implicitly `Sendable` and
pushes the threading down into the two recorders, which own their own synchronisation.

### Data flow

```
menubar toggle
 └─ AppController.startSession
     └─ RecordingSession
         ├─ MicRecorder          → .plume/mic.caf      (AVAudioEngine tap, AAC mono)
         └─ SystemAudioRecorder  → .plume/system.caf   (CoreAudio process tap)
     └─ stop → meta.json (+ per-track start offsets) → state.json: recorded

TranscriptionCoordinator (actor, serial queue; .plume/state.json IS the queue)
 ├─ ParakeetEngine.transcribe(mic)    → [TranscriptSegment]        speaker = me
 ├─ ParakeetEngine.transcribe(system) → [TranscriptSegment]
 │   └─ OfflineDiarizer.diarize(system) → [DiarizedTurn]
 │       └─ SpeakerAttribution        per-word overlap, re-segmented on speaker change
 ├─ shift each track by its offset onto one clock
 ├─ EchoFilter.dropEchoes            drop mic segments duplicating far-end speech
 ├─ deterministic 4-level sort
 ├─ MeetingDocument.render           → meeting.md  (notes / summary / transcript regions)
 ├─ delete audio                     ← irreversible, by design
 └─ state.json: transcribed

[human trigger only]
SummaryEngine (actor)
 ├─ Prompt.single  → OllamaClient.stream  (/api/chat, NDJSON)
 │   └─ on exceed_context_size_error → Prompt.split → map-reduce with carry-forward digests
 ├─ buffer fully, then MeetingDocument.updateRegion(.summary)
 ├─ MeetingIdentityDeriver → title applied; speaker names → .plume/proposals.json (await a click)
 ├─ MeetingAdmin.renameFolder
 └─ state.json: summarized
```

### Persistence

The folder is the database. `.plume/state.json` is simultaneously the durable stage machine and
the work queue — `resumePending()` rescans at launch, so a crash mid-transcription just retries.
`MeetingLibrary` builds the history list by reading only the first 4 KB of each `meeting.md`, so a
folder of two-hour transcripts still lists cheaply.

### UI

Two surfaces over one object. `MeetingPanelController` drives three `NSWindow`s (pill, recording
panel, wrap-up window — separate because `styleMask` is immutable after init), `HistoryModel`
drives the Meetings window. Both conform to `MeetingDetailModel` and render the shared
`MeetingDetailView`.

### What is already done well

Worth stating, because it constrains what a refactor should touch:

- **The invariants are enforced in code, not just documented.** `FileManager.replaceItemAt` rather
  than `Data.write(.atomic)`; `markerRange` throws instead of appending; `trashItem` rather than
  `removeItem`; summaries buffered and swapped in only on success.
- **The pinned dependency is genuinely contained.** Every FluidAudio call sits behind `Diarizing`
  or `TranscriptionEngine` in two files. A version bump stays a small diff.
- **Prompt injection is treated as a real threat** — fenced untrusted input, and schema-constrained
  decoding that bounds what the identity pass can return.
- **`Config` already solved the "don't re-read on every access" problem** with an mtime-keyed cache.
- **The error taxonomy carries the data needed to act**: `contextExceeded` carries token counts,
  which is what lets map-reduce size its windows instead of guessing.

The problems below are all *local*. None of them is "this design is wrong."

---

## 2. Problem areas

Ranked by cost of leaving them. Categories: **C**orrectness · **D**uplication · **P**erformance ·
**M**aintainability.

### P2 · The summary model is frozen at app launch — **C**

`MeetingPanelController.swift:22` and `HistoryWindow.swift:44` each hold
`private let engine = SummaryEngine()`, both constructed inside `AppController.init` — i.e. at
launch. `SummaryEngine.init` defaults `client: OllamaClient = OllamaClient()`, and
`OllamaClient.init` defaults `model: String = Config.summaryModel()`. That default is evaluated
once, then stored.

Every *other* reader of the model builds a fresh client and therefore sees the current value:
`MeetingDetailView.checkBackend()` (line 120), `SettingsWindow` (line 228), `Doctor` (line 36).

So after changing the model in Settings, and until relaunch:

- the Settings picker shows the new model,
- the caption beside **Summarise** says the new model is ready,
- `doctor` validates the new model,
- the summary is generated by the **old** model,
- and `stampFrontmatter` records `model:` as the **old** name — so the provenance in `meeting.md`
  is wrong, in a file that is the only surviving record of the meeting.

`num_ctx` does *not* have this bug — `Options.numCtx` is a per-instance property default,
re-evaluated on each `Options()` — which is exactly what makes the model case easy to miss.

Confirmed: no call site anywhere passes an explicit model, and nothing mutates `baseURL` or
`model` after init.

### P1 · Two meeting surfaces duplicate ~120 lines of model logic, and have already diverged — **D M**

`MeetingPanelController` and `HistoryModel` implement the same six behaviours twice:

| Concern | `MeetingPanelController` | `HistoryModel` |
|---|---|---|
| speaker rows from transcript + proposals | 202–212 | 105–114 |
| debounced notes autosave (1.2 s `Timer`) | 155–168 | 119–137 |
| summarize + progress mapping | 222–256 | 197–234 |
| rename / merge / `edit` | 291–309 | 236–254 |
| `*pending*` → `""` normalisation | 280–287 | 102–104 |
| locate the renamed folder by stamp prefix | 272–278 | 227–230 |

The divergence has already happened. On a mid-stream failure the panel reloads the on-disk summary
(`MeetingPanelController.swift:252`); history sets `error` and leaves the partial stream on screen
(`HistoryWindow.swift:220–222`). The **file** is correct in both cases — invariant 2 holds — but the
history window displays text that is not in `meeting.md`, which is the same class of "the screen
disagrees with the record" that invariant 2 exists to prevent.

AGENTS.md records that these two surfaces drifted once before (only one rendered markdown, only one
had notes) and that `MeetingDetailView` was extracted to stop it. The extraction stopped at the
view and left the model behind.

### P4 · `TemplateStore.all()` does full disk I/O on every SwiftUI body evaluation — **P**

`all()` = `seedIfNeeded()` (createDirectory + 4× `fileExists`) + `contentsOfDirectory` + read and
parse every `.md`. **Measured: 0.474 ms per call** (optimised build, warm cache, 2000 iterations,
seed-sized template files).

It is exposed as a computed property on three view models — `MeetingPanelController.swift:40`,
`HistoryWindow.swift:59`, `SettingsWindow.swift:45` — and read from inside `body`:

```swift
// MeetingDetailView.swift:148-150, inside summarizeBar, inside body
Picker("", selection: $model.templateID) {
    ForEach(model.templates, id: \.id) { Text($0.name).tag($0.id) }
}
```

`MeetingDetailView.body` re-evaluates on every observed change, including every keystroke in the
notes editor (`.onChange(of: model.notes)` at line 139 registers the dependency). So each character
typed during a meeting costs a directory listing plus four file reads and parses on the main thread.
`summarize()` pays it 2–3× more: `TemplateStore.template(id:)` and `TemplateStore.default()` each
call `all()` again.

### P5 · Date formatters constructed per item on list paths — **P**

Measured (20 000 iterations each):

| | per call |
|---|---|
| `DateFormatter` constructed fresh (current `MeetingEntry.subtitle`) | 0.0224 ms |
| `DateFormatter` reused | 0.0027 ms |
| `Date.FormatStyle` (value type, `Sendable`) | 0.0017 ms |
| `ISO8601DateFormatter` constructed fresh (current `parseDate`) | 0.0925 ms |
| `ISO8601DateFormatter` reused | 0.0325 ms |

- `MeetingLibrary.parseDate` (84–92) builds one `ISO8601DateFormatter` per meeting, and a second
  when the first fails. On a 300-meeting folder that is ~28 ms of pure formatter construction —
  comparable to the cost of all 300 file reads it accompanies.
- `MeetingEntry.subtitle` (18–32) builds a `DateFormatter` per call, from inside a `List` row body.
- `MeetingLibrary.entries(in:)` runs on the main actor from `HistoryModel.reload()`, and again after
  every summarize, rename and delete.

### P6 · Three hand-rolled copies of "replace the frontmatter block", disagreeing on failure — **D M**

`MeetingDocument.updateFrontmatter:242–247`, `SummaryEngine.stampFrontmatter:188–192`,
`SpeakerEditing.apply:103–109`. All three search for `"\n---\n"` and splice.

They do not agree on what happens when it is missing: `updateFrontmatter` throws `missingMarker`;
the other two silently return. So a `meeting.md` whose frontmatter was hand-deleted loses its
`template:` / `model:` / `summary_generated:` stamp with no error raised, logged or displayed —
inside the one module whose stated purpose is making silent partial writes impossible.

`MeetingDocument.setValue` (251–257) is the canonical "set or append a key", and
`stampFrontmatter` re-implements it as a nested `func set` (176–182).

### P7 · Invariant-1 errors are swallowed at the UI boundary — **C M**

`MeetingDocument.updateRegion` throws `missingMarker` deliberately — "fail loudly if a marker is
missing" is invariant 1. Both call sites discard it:

- `MeetingPanelController.swift:174` — `try? MeetingDocument.updateRegion(.notes, …)`
- `HistoryWindow.swift:135` — same

A user who deletes the `<!-- plume:notes -->` markers gets every subsequent note edit silently
dropped from `meeting.md`, with `detailError` staying `nil`. The blast radius is bounded — the text
still reaches `.plume/notes.md` — but the design intent is defeated at the last hop, and the
summariser reads the *document*, so the next summary silently sees stale notes.

### P3 · Two `SummaryEngine` instances can run concurrently against one Ollama — **M**

Panel and history each own one; nothing coordinates them. Both end with `client.unload()`
(`keep_alive: 0`), so the first to finish evicts the model the second is still streaming from.
Ollama reloads on demand, so the cost is latency rather than corruption — but it is an avoidable
race, and it doubles peak model memory on the 16 GB machine PLAN R5 budgets for.

**The fix has a visible consequence, so it is a decision rather than a tidy-up.** `SummaryEngine` is
an actor: sharing one instance *serialises* the two surfaces, so summarizing an old meeting from
history while the panel's wrap-up summary is still running would queue rather than run — the second
surface sits on "Loading the model…" for however long the first takes, with no indication it is
waiting rather than working. That is still better than the current race, and on a 16 GB machine
serialising is what R5 asks for; but if it ships, the queued state needs to say so.

### P8 · The panel polls for the transcript, and the poll outlives its session — **M**

`MeetingPanelController.startPolling` (180–186) fires every 2 s and stops only when `meeting.md`
appears. If transcription fails, it never stops — it runs for the process lifetime, doing a
`fileExists` and a full file read every 2 s. It is also not bound to a session: `startedRecording`
does not invalidate it, so a timer started for meeting A keeps firing and evaluates against
meeting B's URL.

The comment explains the polling as avoiding coupling to the coordinator's internals — but the
decoupled channel already exists: `TranscriptionCoordinator.setStatusHandler` fans out to
`AppState`, which is documented as "single source of truth for everything the UI shows".

**Re-reading R11 raises this from tidy-up to a real fix.** A status carrying the *session URL* lets
the panel check that the transcript that just arrived belongs to the meeting it is showing. Today's
timer cannot: it captures nothing, reads whatever `session` currently holds, and back-to-back calls
(R11) are the designed-for case where those differ.

### P13 · Two meetings started in the same minute are indistinguishable to the rename lookup — **C**

*Found on the second pass, from PROGRESS.md.*

`RecordingSession.init:55–60` disambiguates a folder collision by appending a counter, so two
recordings started inside the same minute produce `2026-08-15-1400` and `2026-08-15-1400-2`. Both
post-summarize relocations then search with `first { $0.lastPathComponent.hasPrefix(stamp) }`, where
`stamp` is `prefix(15)` — which matches **both** folders, resolved in `contentsOfDirectory` order.

`MeetingAdmin.renameFolder` also builds the new name from `prefix(15)`, so `2026-08-15-1400-2`
becomes `2026-08-15-1400-<slug>`: the counter is dropped, and the two meetings' folder names then
differ only by slug. After summarizing one of them, the panel can adopt the *other* meeting's folder
as its session, and the history window can move its selection to it.

PROGRESS.md records the coupling deliberately — *"the `yyyy-MM-dd-HHmm` prefix is preserved because
the list sorts on it and renamed sessions are located by matching it"* — and R11 (back-to-back
calls) is precisely the scenario that produces a same-minute pair. The consequence is bounded:
nothing is overwritten, the wrong meeting is merely followed. But it is silent, and back-to-back is
the case the panel was designed for.

### P9 · The `yyyy-MM-dd-HHmm` prefix length is hardcoded in three places — **D**

`.prefix(15)` in `MeetingAdmin.renameFolder:63`, `HistoryModel.summarize:227`, and
`MeetingPanelController.locateRenamed:274`. The format string that *defines* 15 lives in a fourth
file, `RecordingSession.swift:46`. Changing the folder format silently breaks post-rename selection
in two UI paths — silently, because both fall back to "keep the old selection".

**P13 changes this fix.** Sharing the constant would make three fragile call sites consistent rather
than correct. `SummaryEngine` already computes the authoritative post-rename URL internally
(`finalSession`, line 66) and then discards it; returning it deletes both lookups outright and
leaves one legitimate use of the prefix — constructing the new folder name.

### P11 · Remote-label detection is re-implemented inline and disagrees with `Speaker` — **D**

`TranscriptionCoordinator.swift:216`:

```swift
for label in speakers where label.hasPrefix("S") && label.dropFirst().allSatisfy(\.isNumber) {
```

`allSatisfy` on an empty collection is `true`, so a bare `"S"` counts as remote here, while
`Speaker.init(label:)` maps `"S"` to `.them` — a distinction the suite explicitly pins
(`TranscriptModelTests.swift:26`). Unreachable in practice today; it is the duplication that will
outlive that.

### P12 · The determinism comparator is duplicated into the test rather than exercised — **D M**

`TranscriptionCoordinator.swift:195–200` sorts with a four-level tie-break so that re-running a
session cannot produce a different transcript. `TranscriptModelTests.deterministicOrder` (51–68)
re-declares the identical closure locally and tests *that*. The test passes even if production's
comparator changes — which is the one thing it exists to prevent.

### P10 · `EchoFilter` re-tokenises far-end text once per mic segment — **P**

`isEcho` (54–75) calls `words($0.text)` for every overlapping far-end segment, for every mic
segment. In upstream's measured case (641 mic segments) the same far-end strings are tokenised
hundreds of times. Absolute cost is small; tokenising once up front is a smaller change than the
comment that would explain why it is fine.

---

## 3. Refactoring strategy

Four stages, each independently shippable and test-green. Stage 0 is worth doing whether or not the
rest happens.

### Stage 0 — Correctness, no restructuring — **done 2026-08-16**

1. **P2** — resolve the model per *summarize* rather than per launch (§4.1). Done: `SummaryEngine`
   holds `injected: OllamaClient?` and builds a client in `summarize()`, threaded through
   `generate` / `mapReduce` / `stream` / `stampFrontmatter`. `OllamaClient` untouched.
2. **P7** — route `updateRegion` failures into the error field instead of `try?`. Done at both call
   sites; they collapse into one after Stage 1. History additionally guards on `meeting.md`
   existing, which the panel gets free from `transcriptReady` — an untranscribed meeting is listed
   and has no document yet. Neither site *clears* the error on success: the same field carries
   summarize failures.

The §5 test for P2 was deliberately skipped — it needs two different config values across one
object's lifetime and `Config.path` is a fixed global, so the test would write the developer's real
`config.json`. Blocked on a test-injectable config path; noted in PROGRESS.md.

Scope review of the rest of this document — which items are worth doing and which are not — is in
PROGRESS.md under "Refactor scope". In short: P3 and P8 are not recommended as proposed.

### Stage 1 — Extract the shared meeting behaviour (P1) — **done 2026-08-16**

Landed as proposed: `MeetingContent`, `NotesAutosave`, and a widened `MeetingDetailModel` with
`runSummarize` / `reloadContent` / `applySpeakerEdit`. The panel lost ~90 lines, history ~60. The
deliberate behaviour change was taken: a failed regenerate now reloads from disk in *both*
surfaces. All three constraints below were checked and hold — `flushNotes()` still runs before
`session` is reassigned, `openInEditor`/`revealInFinder` still take a URL, `initialTab` is still
per surface and nothing in the shared extension touches it on selection change.

One thing the proposal didn't anticipate: `MeetingDetailModel` had to gain `Sendable` (free for
two `@MainActor` classes) because the extension hands the engine a `@Sendable` progress closure,
and that closure captures the model as a **named** weak binding — a nested `[weak self]` inside
the enclosing `Task` captures the outer closure's mutable `self`, which strict concurrency
rejects.


Not a new god object — three small pieces:

- **`MeetingContent`** (new, ~40 lines, `Meeting/`): pure loading. `summaryBody(from:)`,
  `speakerRows(session:transcript:)`, `load(session:)`. Testable without any UI.
- **`NotesAutosave`** (new, ~25 lines): the debounce timer, once, with `schedule`/`flush`.
- **`MeetingDetailModel`** gains settable `summary` / `speakerRows` / `isGenerating` /
  `progressNote` / `detailError`, plus `session: URL?` and `summarizingFinished(session:)`, and a
  protocol extension carrying `runSummarize(engine:)` and `reloadContent()`.

Both conformers then shrink to what is genuinely surface-specific: the panel keeps mode/pill/
`isFinished`; history keeps the list, selection, rename and delete.

> **One deliberate behaviour change.** Converging the failure path means picking one. Pick the
> panel's: reload from disk, so the screen shows what `meeting.md` actually contains. This changes
> the history window's behaviour on a failed regenerate — it is the correct direction, but it is a
> change and should be called out in the commit message rather than slipped in.

**Three constraints the extraction must not break.** All three are recorded in the design documents
and none is enforced by a test:

1. **`flushNotes()` runs before `session` is reassigned** (`startedRecording:69`). This is what R11
   depends on: starting a second recording while the first is in wrap-up must not lose the first
   meeting's notes. With the timer moved into `NotesAutosave`, `flush()` still has to happen *before*
   the new session is assigned, or the pending text is written to the wrong meeting.
2. **`openInEditor` and `revealInFinder` keep taking a meeting explicitly** — they must not be folded
   into the new `session`-based helpers. PROGRESS.md records this as a bug already fixed: acting on
   the selection opened the wrong file when right-clicking an unselected row.
3. **`initialTab` stays per surface, never per meeting** (AGENTS.md §2, PLAN F8a). The protocol keeps
   it as a requirement; the shared extension must not set `detailTab` on selection change.

### Stage 2 — Cheap performance (P4, P5, P10) — **P4 done 2026-08-16; P5/P10 deferred**

`TemplateStore.all()` now caches on the file mtimes. P5 and P10 were demoted to "only if the file
is open anyway" — see PROGRESS.md "Refactor scope".


- `TemplateStore`: cache keyed on a directory fingerprint (below). Measured **0.474 ms → 0.056 ms**
  in the steady state, ~8.5×.
- `MeetingLibrary`: build the ISO formatters once per scan; `subtitle` → `Date.FormatStyle`.
- `EchoFilter`: tokenise far-end segments once into a parallel array.

### Stage 3 — Structural tidy — **P6, P9, P11, P12, P13 done 2026-08-16; P3 and P8 declined**

`MeetingDocument.replacingFrontmatter` is the single splice, and `SpeakerEditing.apply` now
throws rather than skipping the block — writing a renamed transcript while dropping the speaker
map would leave the two disagreeing about who said what. `stampFrontmatter` routes through
`updateFrontmatter` (so it re-reads from disk) and logs rather than throwing, because the summary
is already written and `state.json` must still reach `summarized`. P9/P13 were fixed by returning
the session from `summarize()`, which deleted both prefix lookups instead of reconciling them.
`MeetingAdmin` keeps its one legitimate `prefix(15)` — building the new folder name — so no shared
constant was introduced.


- `MeetingDocument.replacingFrontmatter(_:in:path:)` as the single splice; the other two call it and
  stop failing silently.
- `MeetingAdmin.stamp(of:)` / `locate(session:in:)` — one home for the prefix, derived from
  `RecordingSession`'s format rather than typed as `15`.
- `Speaker.isRemoteLabel(_:)`, used by the coordinator.
- `Transcript.sorted(_:)`, used by both production and `TranscriptModelTests`.
- **P3**: one shared `SummaryEngine` owned by `AppController` and injected into both models.
- **P8** (largest, optional): add `.transcribed(session:)` to `TranscriptionCoordinator.Status` and
  let the panel be told rather than poll.

### Explicitly *not* recommended

- **Don't split `MeetingDetailView`.** It is doing exactly the job it was extracted for.
- **Don't touch `MicRecorder`'s `@unchecked Sendable` opportunistically.** AGENTS.md is right:
  removing it means proving every remaining field safe, which is its own piece of work with a real
  risk of introducing an audio-thread bug. Leave it as flagged debt.
- **Don't restructure `EchoFilter`'s LCS or `orderedSpeakers`.** Both are quadratic in shape but on
  inputs that stay small; the comment justifying a change would cost more than the change saves.
- **Don't introduce an index or database for the meetings list.** Folder-as-database is load-bearing
  for the whole design. The list is slow for formatter reasons (P5), not scan reasons.
- **Don't unify the three panel windows.** `styleMask` immutability is measured and documented.

---

## 4. Improved code

Proposed diffs for the highest-value items. Behaviour-preserving except where noted.

### 4.1 · P2 — resolve the model once per summarize, not once per launch

> **Corrected after re-reading AGENTS.md §4.** The first version of this fix made
> `OllamaClient.model` a computed property reading `Config.summaryModel()` on every access. That is
> wrong here. `summarize()` calls `client.stream(…)` and then, minutes later, `client.unload()`
> with `keep_alive: 0`. Re-resolving between the two means a model changed in Settings
> mid-generation would make `unload()` **evict a model Plume never loaded** — breaking *"Unload
> **our** model only — Ollama is shared"* (AGENTS.md §4) and PLAN R5's *"do not evict others"*.
> Resolve per **operation** instead: fixed for the duration of one summarize, current on the next.

```swift
// Sources/PlumeKit/Summary/SummaryEngine.swift
actor SummaryEngine {
    /// Nil in production; an injected client for tests.
    private let injected: OllamaClient?

    init(client: OllamaClient? = nil) { self.injected = client }

    /// One client per summarize, resolved when the operation starts.
    ///
    /// Not stored: `SummaryEngine` is built during `AppController.init` and held for the process
    /// lifetime, so a client built there pins whatever model was configured at launch. Settings,
    /// the readiness caption and `doctor` all build fresh clients and would report the new model
    /// while the old one wrote the summary — and got stamped into frontmatter as provenance, in
    /// the only surviving copy of the meeting.
    ///
    /// Not re-resolved per access either: `unload()` runs minutes after `stream()`, and Ollama is
    /// a shared daemon. Resolving twice could evict a model we never loaded.
    private func makeClient() -> OllamaClient { injected ?? OllamaClient() }

    func summarize(
        session: URL, template: SummaryTemplate,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> URL {          // ← see §4.7: returns the possibly-renamed session
        let client = makeClient()
        …
        try stampFrontmatter(at: meetingURL, template: template, model: client.model)
        …
        try? await client.unload()   // same instance, same model, start to finish
        return finalSession
    }
}
```

`client` becomes a parameter on `generate` / `stream` / `stampFrontmatter` rather than a stored
property — a small threading change. `MeetingIdentityDeriver.derive(client:)` already takes one.
`OllamaClient` itself is untouched, so its `/api/chat`, `num_ctx`, `truncate`/`shift` and
`127.0.0.1` constraints are unaffected.

### 4.2 · P4 — cache the template listing

The obvious cache — key on the directory's mtime — is **wrong here**, and quietly so: editing
`general.md` in place does not change the directory's mtime, so a hand-edited prompt would be
ignored until a file was added or removed. Key on the file mtimes, which one directory read
prefetches:

```swift
// Sources/PlumeKit/Summary/TemplateStore.swift
/// Cached listing, invalidated by the templates' own modification dates.
///
/// Same shape as `Config.current()`, and for the same reason — but keyed on the *files*, not
/// the directory. A directory's mtime only changes when an entry is added or removed, so an
/// in-place edit of an existing prompt would never invalidate a directory-keyed cache. This
/// file advertises "editing one is opening it"; the cache has to honour that.
///
/// Measured: 0.474 ms uncached, 0.056 ms for the fingerprint alone.
private struct Cache: Sendable {
    var templates: [SummaryTemplate]?
    var fingerprint: [String: Date]?
}
private static let cache = OSAllocatedUnfairLock(initialState: Cache())

/// Names and modification dates in one directory read — the prefetch means the per-URL
/// `resourceValues` calls are already resident.
private static func fingerprint() -> [String: Date]? {
    guard let urls = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return nil }
    var out: [String: Date] = [:]
    for url in urls where url.pathExtension == "md" {
        out[url.lastPathComponent] =
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
    return out
}

static func all() -> [SummaryTemplate] {
    if let current = fingerprint(),
        let hit = cache.withLock({ $0.fingerprint == current ? $0.templates : nil })
    {
        return hit
    }
    // Miss: seed first (this is what restores a deleted seed, and what creates the folder on
    // a fresh install), then re-fingerprint — seeding writes files and would otherwise
    // invalidate the entry we are about to store.
    try? seedIfNeeded()
    let parsed = parseDirectory()
    cache.withLock { $0 = Cache(templates: parsed, fingerprint: fingerprint()) }
    return parsed
}

/// The previous body of `all()`, minus seeding.
private static func parseDirectory() -> [SummaryTemplate] { … }
```

`template(id:)` and `default()` need no change — they call `all()` and now get the cache.

### 4.3 · P1 — extract the shared meeting content

```swift
// Sources/PlumeKit/Meeting/MeetingContent.swift  (new)
import Foundation

/// What a meeting looks like once loaded from disk, for whichever surface is showing it.
///
/// The wrap-up panel and the history window were building this twice, ~25 lines apart, and had
/// already diverged on the failure path. `MeetingDetailView` was extracted to stop exactly that
/// drift; this is the other half of the same extraction.
enum MeetingContent {

    struct Loaded: Equatable {
        var summary: String
        var speakerRows: [SpeakerRow]
    }

    /// `*pending*` is the placeholder transcription writes; it is not a summary and must never
    /// be shown as one.
    static func summaryBody(from document: String) -> String {
        guard let existing = try? MeetingDocument.read(.summary, from: document) else { return "" }
        return existing == "*pending*" ? "" : existing
    }

    /// Remote speakers only — "me" is you by construction and has nothing to rename.
    static func speakerRows(session: URL, transcript: String) -> [SpeakerRow] {
        let proposals = MeetingIdentity.load(from: session)?.speakers ?? []
        return SpeakerEditing.speakers(in: transcript)
            .filter { $0.label != Speaker.me.label }
            .map { entry in
                SpeakerRow(
                    label: entry.label, samples: entry.samples,
                    proposal: proposals.first { $0.label == entry.label })
            }
    }

    /// Nil when `meeting.md` isn't there yet — a recorded-but-untranscribed meeting, which is a
    /// normal resting state rather than an error.
    static func load(session: URL) -> Loaded? {
        guard let document = try? String(
            contentsOf: session.appendingPathComponent("meeting.md"), encoding: .utf8)
        else { return nil }
        let transcript = (try? MeetingDocument.read(.transcript, from: document)) ?? ""
        return Loaded(
            summary: summaryBody(from: document),
            speakerRows: speakerRows(session: session, transcript: transcript))
    }
}
```

```swift
// Sources/PlumeKit/UI/MeetingDetailView.swift — protocol widened, extension added
@MainActor
protocol MeetingDetailModel: AnyObject, Observable {
    // … existing requirements, with these now settable so the shared driver can own them:
    var summary: String { get set }
    var speakerRows: [SpeakerRow] { get set }
    var isGenerating: Bool { get set }
    var progressNote: String { get set }
    var detailError: String? { get set }

    /// The meeting on screen, whichever surface is showing it.
    var session: URL? { get }
    func flushNotes()
    /// Surface-specific epilogue: the panel retires the session, history rebuilds its list.
    func summarizingFinished(session: URL)
}

extension MeetingDetailModel {
    /// The one summarize path. Both surfaces ran their own copy of this; they disagreed on the
    /// failure case, and the history window ended up displaying streamed text that was never
    /// written to `meeting.md`.
    func runSummarize(engine: SummaryEngine, templateID: String) {
        guard let session, !isGenerating else { return }
        flushNotes()                    // debounced edits must reach disk before the engine reads
        detailTab = .summary
        isGenerating = true
        detailError = nil
        summary = ""
        progressNote = "Loading the model…"

        let template = TemplateStore.template(id: templateID) ?? TemplateStore.default()
        Task { [weak self] in
            do {
                try await engine.summarize(session: session, template: template) { progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.summary = progress.partial
                        self.progressNote = progress.windowsTotal > 1
                            ? "Summarising — part \(progress.windowsDone + 1) of \(progress.windowsTotal)…"
                            : "Summarising…"
                    }
                }
                await MainActor.run { [weak self] in
                    self?.isGenerating = false
                    self?.summarizingFinished(session: session)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isGenerating = false
                    self.detailError = "\(error)"
                    // Invariant 2: the previous summary is untouched on disk. Show *that*,
                    // not the partial stream that was never written.
                    self.reloadContent()
                }
            }
        }
    }

    /// Re-read summary and speakers from `meeting.md`.
    func reloadContent() {
        guard let session, let loaded = MeetingContent.load(session: session) else { return }
        summary = loaded.summary
        speakerRows = loaded.speakerRows
    }

    /// Shared by both surfaces' rename/merge buttons.
    func applySpeakerEdit(_ transform: (String) throws -> String) {
        guard let session else { return }
        do {
            try SpeakerEditing.apply(
                to: session.appendingPathComponent("meeting.md"), transform)
            detailError = nil
            reloadContent()
        } catch {
            detailError = "\(error)"
        }
    }
}
```

```swift
// Sources/PlumeKit/Meeting/NotesAutosave.swift  (new)
import Foundation

/// Debounced whole-file notes save, shared by both surfaces.
///
/// Notes are free text, so every keystroke would otherwise rewrite the file; 1.2 s keeps that to
/// a trickle while risking at most a second or two of typing on a crash. Both surfaces had their
/// own copy of this timer, and forgetting to invalidate one is a silent double-write.
@MainActor
final class NotesAutosave {
    private var timer: Timer?
    private let interval: TimeInterval
    private let save: () -> Void

    init(interval: TimeInterval = 1.2, save: @escaping () -> Void) {
        self.interval = interval
        self.save = save
    }

    func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    func flush() {
        timer?.invalidate()
        timer = nil
        save()
    }
}
```

### 4.4 · P7 — stop swallowing invariant-1 failures

With Stage 1 in place there is one call site left:

```swift
/// Keep meeting.md's Notes region in step once it exists, so a summary never reads a stale copy.
///
/// The error is surfaced rather than dropped: `updateRegion` throws only when a marker is
/// missing, which means the user's own edit has made the file unwritable by us (invariant 1).
/// Silently continuing would keep accepting notes that never reach the document the summariser
/// actually reads.
private func syncNotesRegion() {
    guard let session, transcriptReady else { return }
    do {
        try MeetingDocument.updateRegion(
            .notes, at: session.appendingPathComponent("meeting.md"), to: notes)
        detailError = nil
    } catch {
        detailError = "\(error)"
    }
}
```

### 4.5 · P5 — reuse formatters on the list path

```swift
// Sources/PlumeKit/Meeting/MeetingLibrary.swift
extension MeetingEntry {
    var subtitle: String {
        var parts: [String] = []
        if let started {
            // `Date.FormatStyle`, not `DateFormatter`: this is called from a List row body, and
            // constructing a DateFormatter per row costs 13× the value-typed style (measured
            // 0.0224 ms vs 0.0017 ms). Also Sendable, so it needs no isolation to hoist —
            // a `static let DateFormatter` would need `nonisolated(unsafe)`, which AGENTS.md §4
            // rules out.
            //
            // Check the rendering once before committing: `.abbreviated`/`.shortened` is meant to
            // match `DateFormatter`'s `.medium`/`.short`, and does in en_GB, but this is a
            // user-visible string and locale behaviour is not something to assume.
            parts.append(started.formatted(date: .abbreviated, time: .shortened))
        }
        …
    }
}

static func entries(in root: URL) -> [MeetingEntry] {
    guard let directories = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isDirectoryKey])
    else { return [] }

    // Built once per scan, not once per meeting: ISO8601DateFormatter costs 0.093 ms to
    // construct and use versus 0.033 ms reused, which on a few hundred meetings is comparable
    // to the cost of reading all their frontmatter.
    let parser = TimestampParser()
    return directories
        .compactMap { entry(at: $0, parser: parser) }
        .sorted { ($0.started ?? .distantPast) > ($1.started ?? .distantPast) }
}

/// Local to one scan, so the non-Sendable formatters never cross an isolation boundary.
private final class TimestampParser {
    private let withOffset: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    /// Older sessions were written in UTC with fractional seconds.
    private lazy var fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func date(from value: String) -> Date? {
        withOffset.date(from: value) ?? fractional.date(from: value)
    }
}
```

### 4.6 · P6 — one frontmatter splice

```swift
// Sources/PlumeKit/Meeting/MeetingDocument.swift
/// Replace the frontmatter block, leaving every region byte-identical.
///
/// Was written out three times — here, in `SummaryEngine.stampFrontmatter` and in
/// `SpeakerEditing.apply` — and the three disagreed on failure: this one threw, the other two
/// returned silently, so a document with hand-deleted frontmatter lost its provenance stamp
/// with no error anywhere. One implementation, one failure mode.
static func replacingFrontmatter(
    _ pairs: [(String, String)], in document: String, path: String = "meeting.md"
) throws -> String {
    guard let end = document.range(of: "\n---\n") else {
        throw DocumentError.missingMarker(
            region: "frontmatter", marker: "closing ---", path: path)
    }
    return renderFrontmatter(pairs) + String(document[end.upperBound...])
}
```

```swift
// Sources/PlumeKit/Summary/SummaryEngine.swift
private func stampFrontmatter(at url: URL, template: SummaryTemplate) throws {
    do {
        try MeetingDocument.updateFrontmatter(at: url) { pairs in
            MeetingDocument.setValue(template.id, for: "template", in: &pairs)
            MeetingDocument.setValue(client.model, for: "model", in: &pairs)
            MeetingDocument.setValue(
                ISO8601DateFormatter().string(from: Date()), for: "summary_generated", in: &pairs)
        }
    } catch {
        // Deliberately not rethrown — the same shape as the identity-derivation failure twenty
        // lines below, and for the same reason. The summary region is already written and
        // correct; a document whose frontmatter the user removed must not lose its summary, nor
        // stall before `state.json` advances to `summarized` (AGENTS.md §4: blocking must
        // preserve the stage reached). Logged rather than silent, which is what the previous
        // inline splice did.
        FileHandle.standardError.write(Data("could not stamp frontmatter: \(error)\n".utf8))
    }
}
```

Routing through `updateFrontmatter` also means the file is **re-read from disk** before the stamp,
rather than spliced into the copy read before the summary was written — closer to invariant 1's
"re-read from disk before every write" than the current code.

### 4.7 · P9 / P11 / P12 — the small ones

```swift
// Sources/PlumeKit/Summary/SummaryEngine.swift — return the renamed session instead of
// making two call sites guess at it.
//
// Both surfaces searched the parent directory for a folder whose name starts with the
// `yyyy-MM-dd-HHmm` stamp. That is ambiguous by construction: `RecordingSession` disambiguates
// a same-minute collision with a `-2` suffix, and `renameFolder` drops it — so two meetings
// recorded in the same minute end up differing only by slug, and the prefix match can return
// either. Back-to-back calls (R11) are the case that produces it. The engine already knows the
// answer; handing it back removes the guess rather than making both copies of it agree.
@discardableResult
func summarize(session: URL, template: SummaryTemplate, onProgress: …) async throws -> URL

// MeetingAdmin.swift — one legitimate use of the stamp is left: building the new folder name.
/// Length of the `yyyy-MM-dd-HHmm` folder prefix, derived from the format rather than typed.
static let stampLength = "yyyy-MM-dd-HHmm".count
```

`MeetingPanelController.locateRenamed` and the prefix search in `HistoryModel.summarize` both
delete. In the shared driver from §4.3, `summarizingFinished` receives the authoritative URL:

```swift
let finalSession = try await engine.summarize(session: session, template: template) { … }
await MainActor.run { [weak self] in
    self?.isGenerating = false
    self?.summarizingFinished(session: finalSession)
}
```

```swift
// Sources/PlumeKit/Transcription/TranscriptionEngine.swift
extension Speaker {
    /// Whether a written label denotes a diarized remote speaker ("S1", "S2"…).
    ///
    /// Agrees with `init(label:)` by construction. The coordinator used to test this inline as
    /// `hasPrefix("S") && dropFirst().allSatisfy(\.isNumber)`, which accepts a bare "S" —
    /// `allSatisfy` is true on the empty collection — while `init(label:)` maps it to `.them`.
    static func isRemoteLabel(_ label: String) -> Bool {
        if case .remote = Speaker(label: label) { return true }
        return false
    }
}
```

```swift
// Sources/PlumeKit/Transcription/TranscriptionCoordinator.swift
extension Transcript {
    /// Deterministic order for merged segments.
    ///
    /// Swift's sort is not stable, so ties on `start_ms` would order arbitrarily and re-running
    /// the same session could produce a different transcript. Lives here rather than inline so
    /// the test can exercise *this* comparator — it previously re-declared an identical closure
    /// locally, and therefore passed regardless of what production did.
    static func sorted(_ segments: [Segment]) -> [Segment] {
        segments.sorted { a, b in
            if a.start_ms != b.start_ms { return a.start_ms < b.start_ms }
            if a.end_ms != b.end_ms { return a.end_ms < b.end_ms }
            if a.speaker != b.speaker { return a.speaker < b.speaker }
            return a.text < b.text
        }
    }
}
```

---

## 5. Sequencing, risk and verification

| Stage | Items | Files touched | Risk | Verified by |
|---|---|---|---|---|
| 0 | P2, P7 | 3 | Low | New test: a client built before a config change reports the new model |
| 1 | P1 | 4 (+2 new) | **Medium** — one deliberate behaviour change | Existing 114; new tests for `MeetingContent.summaryBody` / `speakerRows` |
| 2 | P4, P5, P10 | 3 | Low | New test: editing a template file in place is picked up (guards the cache-key trap) |
| 3 | P6, P9, P11, P12, P3, P8 | 7 | Low except P8 | `Transcript.sorted` test switches to production code; P8 needs a manual failed-transcription check |

Stage 1 is the only one that changes observable behaviour, and only on the regenerate-failure path.
Everything else is behaviour-preserving.

**Test coverage the refactor should add** (currently absent, and each guards something the review
found):

1. A summary model changed in config is used by the next generation — pins P2.
2. `MeetingContent.summaryBody` maps `*pending*` to empty and anything else through — pins the
   normalisation both surfaces open-coded.
3. `TemplateStore.all()` reflects an in-place edit to an existing template file — pins the cache
   key against the directory-mtime trap.
4. `Transcript.sorted` is called by `TranscriptModelTests` rather than re-implemented — makes the
   determinism invariant actually tested.

**AGENTS.md** would need updating in the same commit, per its own rule: the "wrap-up panel and the
history window share `MeetingDetailView`" paragraph becomes "share `MeetingDetailView` *and* the
summarize/reload path", and section 4 gains a line about `TemplateStore`'s cache key being the file
mtimes rather than the directory's, with the reason. Bump the review date.

---

## 6. Two documented mitigations that appear not to be implemented

Found while checking the review against PLAN.md. **Neither is a refactoring item** — both are
pre-existing, both are plausibly known debt, and neither affects anything proposed above. Flagged
only in case they are news.

**R7 — first-run model download still happens lazily.** PLAN R7's mitigation is *"Pull models from
`doctor` at first launch using FluidAudio's `progressHandler`"*, and PROGRESS.md restates it as a
decision on 2026-08-14: *"Models must be pulled from `doctor` at first launch with progress, never
lazily after the first meeting ends."* In the code, `Doctor.checkTranscription:196–197` only
*reports* — `AsrModels.modelsExist(at:version:)` — and the only `downloadAndLoad` call is
`ParakeetEngine.prepare():31`, on the transcription path. So on a fresh machine the 464 MB download
still happens after the first meeting ends, on whatever network, with no progress UI. The check does
warn beforehand, with a remediation string, which may well be judged enough.

**R8 — no temp-directory cleanup on launch.** PLAN R8: FluidAudio's `makeDiskBackedSource` writes
the whole file as 16 kHz mono float32 into `temporaryDirectory` before mmapping — ~460 MB for a
two-hour meeting — *"leaked if it crashes mid-diarization"*, mitigated by *"Clean up on launch as
well as on completion."* `grep -rn "temporaryDirectory" Sources/` returns nothing, so the
launch-time sweep does not exist. Low severity: macOS reclaims `NSTemporaryDirectory()` eventually,
and only a crash *during* diarization leaks.

**One small duplication not worth its own finding:** the `h:mm:ss` / `m:ss` rendering is written out
three times — `AppState.elapsedText:71–78`, `NotesStore.clock:48–54`, `Transcript.clock:413–418`.
Two of them have to agree for a reason: a note stamped `[12:04]` is meant to point at the transcript
line stamped `[12:04]`. One `Clock.text(seconds:)` would make that structural. Fold it into Stage 3
if you touch those files anyway.