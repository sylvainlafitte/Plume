# Working on Plume

Local-only macOS meeting recorder → transcript → AI summary. Menubar app, no cloud.
Forked from [digimata/quill](https://github.com/digimata/quill) (MIT).

> **This file carries what you cannot infer from the code**: things that are irreversible if you
> get them wrong, decisions that look like omissions, and platform traps that fail silently.
> It is ordered by what a change is likely to cost, not by topic.

**The doc set, and what to read when.** This file is the only required reading; the rest are
consulted, not read front to back.

| | What it is | Read it when |
|---|---|---|
| **AGENTS.md** (here) | How Plume works now, and what will cost you if you get it wrong | Always — it is loaded into every session |
| **[docs/PROGRESS.md](docs/PROGRESS.md)** | The log: current state, next action, decisions with their *why*, and dead ends | Starting a session, or before retrying something that smells previously-tried |
| **[docs/PLAN.md](docs/PLAN.md)** | Pre-implementation design record. Source of the `F*`/`R*` numbers cited elsewhere | A reference points there. Not orientation material — most of it is now history |
| **[docs/archive/](docs/archive/)** | Closed work, kept for its reasoning | Almost never |

**Precedence:** the **code** wins over this file (if they disagree, fix the file in the same
commit); this file wins over PLAN.md, which is *why*, not *what is*.

## 0. How Plume is put together

One SwiftPM package. `Sources/PlumeKit/` holds everything (`Audio`, `Transcription`, `Meeting`,
`Summary`, `UI`, plus `App`/`AppState`/`Config`/`Doctor`/`Log`/`LoginItem`/`Notify` at the root);
`Sources/plume/main.swift` is a five-line shim so the test target can `@testable import` without
depending on an `@main` target.

```
menubar toggle
 └─ AppController.startSession → RecordingSession
     ├─ MicRecorder          → .plume/mic.caf      (AVAudioEngine tap, AAC mono)
     └─ SystemAudioRecorder  → .plume/system.caf   (CoreAudio process tap)
     └─ stop → meta.json (+ per-track start offsets) → state.json: recorded

TranscriptionCoordinator (actor, serial; .plume/state.json IS the queue)
 ├─ ParakeetEngine.transcribe(mic)     → speaker = me
 ├─ ParakeetEngine.transcribe(system)
 │   └─ OfflineDiarizer.diarize → SpeakerAttribution (per-word overlap, re-segmented on change)
 ├─ shift each track by its offset onto one clock
 ├─ EchoFilter.dropEchoes → Transcript.sorted (deterministic 4-level tie-break)
 ├─ MeetingDocument.render → meeting.md (notes / summary / transcript regions)
 ├─ delete audio                      ← irreversible, by design
 └─ state.json: transcribed

[human trigger only — see §2]
SummaryEngine (actor)
 ├─ Prompt.single (VocabularyStore glossary + notes guidance) → OllamaClient.stream,
 │      falling back to map-reduce on contextExceeded
 ├─ buffer fully, then MeetingDocument.updateRegion(.summary)
 ├─ MeetingIdentityDeriver → title applied; speaker names → proposals.json (await a click)
 ├─ MeetingAdmin.renameFolder → returns the new session URL
 └─ state.json: summarized
```

**Launch does more than start the menu bar**, and the order matters:

```
applicationDidFinishLaunching
 ├─ TempSweep.run            reclaim a crashed diarization's scratch files (R8)
 ├─ DoctorReport.run         no probes — they cost ~2s and play a tone
 ├─ SetupWindowController    shown only if the models are missing
 ├─ GlobalHotkey.register    ⌥⌘R; logs and continues if another app owns it
 ├─ NotificationRouter       set BEFORE anything posts, or a click has nowhere to go
 ├─ CameraWatch.startIfEnabled   opt-in; usually does nothing
 └─ transcription.resumePending  the queue is just a rescan of state.json
```

**Windows, and who owns them.** `MeetingPanelController` → three `NSWindow`s (pill, recording,
wrap-up); `HistoryWindowController` → Meetings; `SettingsWindowController` → Settings;
`SetupWindowController` → Setup & Checks. Everything readiness-related renders `DoctorReport`:
that window and `plume doctor` are two renderers of one engine (§2).

**The folder is the database.** No index. `.plume/state.json` is simultaneously the durable stage
machine and the work queue, so `resumePending()` at launch just rescans; `MeetingLibrary` lists
history by reading the first 4 KB of each `meeting.md`.

**Three isolation domains, chosen per layer**: `@MainActor` for `AppController`, `AppState`,
`RecordingSession` and all UI; actors for `TranscriptionCoordinator`, `ParakeetEngine`,
`OfflineDiarizer` and `SummaryEngine` (they own non-`Sendable` model managers and serialise long
work); `OSAllocatedUnfairLock` in `MicRecorder`/`SystemAudioRecorder`, where callbacks are
real-time and an actor hop is not available.

**Two UI surfaces over one object.** `MeetingPanelController` drives three `NSWindow`s (pill,
recording, wrap-up); `HistoryModel` drives the Meetings window. Both conform to
`MeetingDetailModel` and share the view *and* the summarize path — see §4.

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
   honest `S1`. The same rule covers **titles**: a renamed meeting carries
   `title_source: user`, and auto-titling must skip it — otherwise the next Regenerate silently
   undoes the rename.
4. **The user's Notes are theirs.** Nothing reformats them: no imposed bullets, no automatic
   timestamps, no structural markers.
5. **Capture health is only knowable empirically.** A tap without permission returns `noErr`,
   reports a correct 48 kHz stereo format, creates its aggregate device, and fires its IOProc at
   exactly the right rate — with every sample zero. Play a tone, capture, assert non-zero.
   Nothing cheaper is true.
6. **Audio is deleted immediately after transcription, by decision.** Tune against the
   held-aside corpus, never against a real meeting.
7. **Deleting a meeting means the Trash** (`FileManager.trashItem`), never `removeItem`. By the
   time a meeting is listed its audio is already gone, so `meeting.md` is the only copy of
   something that cannot be reproduced from anything else.

## 2. Deliberate, not missing

These look like gaps. They are choices, most of them argued about and some of them reversals of
an earlier design. **Don't "fix" them without asking.**

| Looks like | Actually |
|---|---|
| Call detection never starts a recording | It notifies, and the notification's button starts one — the click is the consent. Off by default (`call_detection`), camera-triggered, and blind to audio-only calls on purpose: a false positive that recorded a meeting is the only unrecoverable failure this feature could have. |
| Setup and diagnostics are one window | Merged 2026-08-16. They asked the same six `DoctorReport` checks, and the split had already produced two readings of one probe. `DoctorReport` is the engine; the window and `plume doctor` are both renderers. Probes stay behind a button (~2 s, plays a tone), and the window auto-opens only when the models are missing. |
| No transcript view in the app | Deliberate. The transcript is summarizer input and text in `meeting.md`. Speaker rows show sample lines so you can identify a voice without one. |
| Notes have no automatic timestamps | Reversed in Phase 5: stamps went stale whenever a line was edited, and most notes aren't anchored to a moment. ⌘T inserts one on purpose. |
| Summarizing is manual | The wrap-up gate is the point — you add final thoughts *then* summarize. A meeting resting at `transcribed` forever is normal. |
| Only four templates, no template editor | Templates are markdown files in a folder; editing one means opening it. A JSON store and an editor UI were both declined. |
| No in-app markdown editor | Declined. The files are markdown in a folder and every Mac has a good editor. |
| Speaker names aren't applied automatically | Invariant 3. |
| Audio vanishes after transcription | Invariant 6, a requirement not a bug. |
| The panel opens on Notes but Meetings opens on Summary | Deliberate, not an inconsistency. The panel is where you *write* a record; the window is where you *read* one. Fixed per surface, never per meeting — a default that varied with the selection would make the tab jump as you scroll the list. |
| Summarize sits below the tabs, not inside Notes | So the default tab isn't load-bearing: the action stays reachable from either tab. It also leaves the bottom edge free for a future per-meeting Ask tab. |
| A recording starts as the pill, and both expanded modes share one resizable frame | Reversed together. Two fixed sizes (340×300 recording, 430×580 wrap-up) assumed a live call wanted a smaller footprint — moot once the panel is only on screen when you deliberately open it. Collapse and expand must **pivot on the same corner**, or a round-trip drifts the pill by the difference in size. Top-right is only the *preferred* corner: `PanelAnchor` flips an axis when expanding from it would run off the screen, and the chosen corner is stored until the next expand — re-deriving it at collapse time is what makes the pill wander (covered by `PanelAnchorTests`). |
| Two echo settings, not one | Different points in the pipeline and not interchangeable: `transcript_echo_filter` removes duplicates from the finished transcript (safe, default on), `mic_voice_processing` stops the echo reaching the recording but makes macOS duck all other audio for the whole meeting. Presented together, weaker one first. |
| No UI for the vocabulary file, and it cannot fix the transcript | Both deliberate. `Vocabulary.md` is a markdown file beside `Templates/` — same premise, edited in your own editor. And it is read at *summary* time: Parakeet exposes no biasing hook (FluidAudio's `vocabulary` is the model's own token table), so a misheard term is already in the transcript, whose audio is gone. The glossary makes the **summary** spell it right; rewriting the transcript from it was rejected as invariant-1 territory. |
| `transcription.enabled` has no toggle in Settings | Off, a recording rests at `recorded` forever — no transcript, no summary, no `meeting.md`. A switch that silently turns the whole app off doesn't belong beside ordinary preferences. The config key still works for the CLI. |
| No Dock icon, and windows aren't in ⌘-Tab | Accessory apps are absent from ⌘-Tab **by rule**, not by window configuration — the only lever is `NSApp.setActivationPolicy(.regular)`, which brings a Dock icon and a real menu bar. Declined 2026-08-15. Windows are reached from the menu bar. |
| `state.json` carries a `machine` id, and `resumePending` skips foreign sessions | For the case where the meetings root is a *synced* folder shared by two Macs. Looks like dead code on a single Mac — `isOwnedByThisMachine` is always true there, including for pre-stamp sessions, which is why it's `String?`. Without it the second Mac adopts the first's `recorded` session and transcribes audio that may still be downloading, then deletes it (invariant 6). Only the unattended path is guarded; recording enqueues its own session directly. The id lives beside `config.json`, never in the meetings root — it must not sync. |
| `expected_participants` defaults to 2 | 1:1 is the modal meeting; the cap makes over-splitting one voice structurally impossible. Fix a mis-split with this, **never** by lowering the diarizer threshold. |

Genuinely **not built yet** (different thing): Phase 7 Ask — now scoped as its own **global** surface with the per-meeting tab as the
N=1 case, not a row and not only a tab (PROGRESS.md, "Road to public, and to Ask").

## 3. Build & run

```bash
swift build && swift test                      # library + 165 tests
./build-app.sh release run                     # assemble, sign, install, launch
./build-app.sh release notarize                # release: notarize, staple, dist/Plume-<v>.zip
./.build/debug/plume doctor                    # checks — but see below
./.build/debug/plume diarize <file.caf>        # dev: print diarizer turns
./.build/debug/plume summarize <session-dir>   # dev: summarize in place
/Applications/Plume.app/Contents/MacOS/plume loginitem [register|unregister]
```

The last one only means anything from inside the bundle: `SMAppService` keys on the *calling*
app, so a bare binary always reports `notFound`. Runtime log: `~/Library/Logs/Plume/plume.log`
(rotates once at 1 MB); per-session transcription logs stay in `.plume/transcribe.log`.

**Never test audio capture with `swift run`; the result is meaningless either way.** A bare
binary has no TCC identity — capture is attributed to the *responsible process*, i.e. your
terminal. Without that grant you get full-length silence with no error; with it, capture works
while proving nothing about the app. Both were observed hours apart from one binary. Only the
`.app` has a self-owned grant.

**`build-app.sh` stages in `/tmp` on purpose.** This repo is under `~/Documents`, which iCloud
stamps with `com.apple.FinderInfo` — what codesign rejects as *"resource fork, Finder
information, or similar detritus"*. Stripping it loses a race with the file provider.
(`com.apple.provenance` is on everything, is **not** removable, and codesign tolerates it —
not the culprit.) Signing prefers **Developer ID Application** and falls back to Apple Development
(ad-hoc keys its Designated Requirement to the cdhash, so every rebuild would re-prompt for
permissions; Apple Development is refused by Gatekeeper on any Mac but this one). Every build
carries the **Hardened Runtime** — notarization requires it, and it denies the microphone
unless `Resources/Plume.entitlements` grants `com.apple.security.device.audio-input`, failing
the invariant-5 way: no error, all zeros. `./build-app.sh release notarize` re-signs with a
secure timestamp, submits, staples and verifies with `spctl`; the app must be **stapled before
it is zipped**, since a zip cannot carry a ticket. Bundle ID `io.github.sylvainlafitte.plume`,
team `324ZRWQHHV`.

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

**The panel is three windows and must stay that way** — because what separates them lives in
`styleMask`, which cannot be mutated after init. `.titled` is needed to become key so you can
type while a call stays frontmost, but it carries an invisible ~28pt titlebar: below that
height `contentLayoutRect` collapses to **zero** and SwiftUI lays content out below the visible
window. Hence the 22pt pill is `.borderless`. And **wrap-up is an ordinary `NSWindow`**, not a
floating non-activating panel: the reasons to float expire at Stop, and more importantly a
`.nonactivatingPanel` can be *key while another app is active*, where ⌘C reaches nothing —
key equivalents route through the **active** app's main menu. Wrap-up is where a summary gets
copied out, so it cannot be that kind of window. Level and `collectionBehavior` *are* safe to
mutate; `styleMask` is not, which is why this is a third window rather than a mode.
Three more rules the panel depends on, none of them enforced by anything:

- `isMovableByWindowBackground` must stay **off**. On, any drag on content moves the window,
  which silently breaks drag-to-select and swallows drags on the pill. Headers and the pill
  carry an explicit `WindowDragGesture()` instead.
- The pill is **not a `Button`** — a Button treats a drag as a click, so it expanded whenever
  you tried to move it. Plain view + drag gesture + tap gesture.
- The hosting view overrides `acceptsFirstMouse`, and the recording panel calls `makeKey()`
  *without* `NSApp.activate`. A non-activating panel isn't key until clicked, so otherwise the
  first click only raises it and the second reaches the field — and `@FocusState` cannot focus
  anything in a window that isn't key.

Also `hosting.sizingOptions = []`, or SwiftUI's intrinsic size snaps the window back after every
resize; and never mutate `styleMask` after init — typing silently stops working. **Window
metrics generally lose to the hosting view:** `minSize`/`contentMinSize` are set and still
ignored once it is installed, so the floor is enforced in `windowWillResize` — the one point
AppKit asks before committing a drag. Level and `collectionBehavior` are safe to mutate.

**Notifications must be posted *and* routed.** `osascript -e 'display notification'` posts as
**Script Editor** — so clicking one opens Script Editor, not Plume. That was the right trade
before the app had a bundle; now `Notify` uses `UNUserNotificationCenter`, keeping osascript only
for the bundle-less CLI. And the API alone is not enough: with no delegate macOS merely
*activates* the app, which for an accessory app means fronting whatever window exists — a
"you aren't recording" reminder opened **Settings**. `NotificationRouter` sets the delegate and
registers the category *before* anything can post.

**`fixedSize(horizontal:false, vertical:true)` belongs on text that must wrap, never on a
container that must scroll.** Both failures shipped on the same day: on the Settings *container*
it forced the window past the bottom of the screen with no scrollbar (nothing is ever clipped, so
nothing scrolls); missing from the setup window's `Text`s, SwiftUI compressed each to one clipped
line.

**Test-only path overrides are `@TaskLocal`, not locks.** `Config.withPath` and
`TemplateStore.withDirectory` exist so tests don't rewrite the developer's real config and
templates. A lock compiles and is Swift 6-clean but is process-wide, and Swift Testing runs tests
in parallel — the lock version failed `ConfigTests` immediately, because a concurrent suite read
another test's override.

**`SMAppService.mainApp.status == .notFound` means "never registered", not "no bundle."**
`.notRegistered` is what the name suggests and not what macOS returns. `register()` from
`.notFound` succeeds and goes straight to `.enabled`; only a *failing* register is a real
problem.

**A menubar-only app still needs a main menu, or ⌘C beeps.** `LSUIElement` means no menu bar
is drawn, but macOS routes standard editing commands through the **main menu's key
equivalents** — so with no main menu, ⌘C/⌘V/⌘X/⌘A/⌘Z reach nothing and the responder chain
rejects them. The symptom points somewhere else entirely: text selects fine, it just never
copies, in every window. `AppMenu.install()` creates an invisible menu whose only job is that
routing; items use standard selectors with `target: nil` so they walk to the focused text view.

**The wrap-up panel and the history window share `MeetingDetailView` *and* the summarize/reload
path.** They are the same object at different ages — notes, summary, speakers, regenerate — so
changes belong in the shared code, not in one surface. They drifted within a single phase before
the view existed (only one rendered markdown, only one had notes), and drifted again in the model
until 2026-08-16 (on a failed regenerate, only one reloaded from disk — the other left streamed
text on screen that `meeting.md` never contained). The shared parts are now `MeetingDetailView`,
`MeetingDetailModel`'s extension (`runSummarize` / `reloadContent` / `applySpeakerEdit`),
`MeetingContent` (loading) and `NotesAutosave` (the debounce). What stays per surface: chrome,
`initialTab` (panel opens on Notes because you are writing, history on Summary because you are
reading), and `summarizingFinished(session:)` — the panel retires the meeting to history, history
rebuilds its list.

**`SummaryEngine.summarize` returns the session URL, and callers must use it.** Deriving a title
renames the folder. Both surfaces used to find the new one by matching the `yyyy-MM-dd-HHmm`
prefix, which two meetings started in the same minute share — `RecordingSession` disambiguates
with a `-2` suffix and `renameFolder` drops it — so a surface could silently follow the *other*
meeting. Back-to-back calls are a designed-for case, not an edge one.

**`SummaryEngine` holds no `OllamaClient`.** It is built at launch, so a stored client pins the
model configured then, while Settings, the readiness caption and `doctor` all report the current
one — and the wrong name gets stamped into `meeting.md` as provenance. One client per
`summarize()`: current on each run, and *fixed* between `stream()` and `unload()`, or a
mid-generation config change would evict a model Plume never loaded.

**`TemplateStore.all()` caches on the templates' own mtimes, not the directory's.** It is read
from inside `MeetingDetailView.body`, i.e. once per keystroke. A directory's mtime changes only
when an entry is added or removed, so a directory-keyed cache would ignore a hand-edited prompt —
and "editing a template is opening the file" is the whole premise of the folder.

**Swift 6 strict concurrency is on.** `OfflineDiarizerManager` isn't `Sendable` and needs an
owning actor. Don't reach for `@unchecked Sendable`: use a lock. The three that exist each carry
a justification, and `MicRecorder`'s is **inherited debt** — Quill disabled checking on the whole
class; quill#18 locked the fields that raced but the conformance still hides anything new.

**Pipeline state** is `.plume/state.json`: `recorded → transcribed → summarized`, plus
`failed(stage,message)` / `needsPermission` / `cancelled`. Only transcription resumes
automatically, and blocking must preserve the stage reached — otherwise a meeting whose audio is
gone gets re-transcribed into nothing.

## 5. Working habits

`spikes/` is committed on purpose — each has a RESULTS.md and re-runs. Layout is in §0.

`upstream` points at digimata/quill; we cherry-pick from its open PRs and **attribute them in
the commit message**. Upstream merges almost nothing, so don't expect to pull. Note the PRs are
mutually unaware: combining two correct ones has twice produced a bug.

Match Quill's voice — small files, comments explaining *why* a non-obvious thing is done. No new
dependencies without a note in PROGRESS.md saying what they replaced.

**When a bug survives one plausible fix, stop guessing and measure.** Three "fixes" went into a
clipped panel before one diagnostic printed the geometry and found it in seconds.

## Keeping this file current

*Last reviewed against the code: 2026-08-16, after the session machine-ownership stamp.*

**Update it in the same commit as the change, never "later."** A separate documentation pass
does not happen, and a silently wrong constraint is worse than a missing one — the next agent
will trust it.

**The test for belonging here** is not length, it's: *would getting this wrong cost more than
reading it?* Irreversible damage and reversed decisions always qualify. A platform trap qualifies
while it stays invisible — once a test or an obvious code comment enforces it, cut it here and
keep the pointer. Design rationale belongs in PLAN.md; status and dead ends in PROGRESS.md;
anything derivable from reading the code belongs nowhere. §0 is the exception that proves it:
the shape *is* derivable, but only by reading a dozen files, and every session needs it.

Bump the date when you edit. If it is far behind HEAD, spend five minutes checking sections 1
and 4 against reality before trusting them.
