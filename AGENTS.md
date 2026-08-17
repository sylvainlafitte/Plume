# Working on Plume

Local-only macOS meeting recorder → transcript → AI summary. Menubar app, no cloud.
Forked from [digimata/quill](https://github.com/digimata/quill) (MIT).

> **This file carries what you cannot infer from the code**: things that are irreversible if you
> get them wrong, decisions that look like omissions, and platform traps that fail silently.
> It is ordered by what a change is likely to cost, not by topic.

**The doc set.** This file is the only required reading; the rest are consulted.

| | What it is | Read it when |
|---|---|---|
| **AGENTS.md** (here) | How Plume works now, and what will cost you if you get it wrong | Always — it is loaded into every session |
| **[README.md](README.md)** | The only document a user reads: what Plume is, how to install it, what it does, what leaves the machine | You change anything a user sees, installs or configures — and then update it in the same commit |
| **[docs/DECISIONS.md](docs/DECISIONS.md)** | Dead ends with their evidence, and calls already taken for work not yet built | Before retrying something that smells previously-tried, or starting Ask |
| **[spikes/](spikes/)** | Three measured results (TCC identity, panel window config, Ollama `num_ctx` cost) | A comment cites one and you want the numbers |

**Precedence:** the **code** wins over this file — if they disagree, fix the file in the same
commit.

## 0. How Plume is put together

One SwiftPM package. `Sources/PlumeKit/` holds everything: the `Audio`, `Transcription`,
`Meeting`, `Summary` and `UI` folders, plus eleven files at the root — `App`, `AppState`,
`AudioProbe`, `Config`, `Doctor`, `Log`, `LoginItem`, `MTimeCache`, `Notify`, `RecordingSession`,
`UpdateCheck`. `Sources/plume/main.swift` is a five-line shim so the test target can
`@testable import` without depending on an `@main` target.

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
 ├─ AppController()          ← everything below happens inside its init, first of all
 │   ├─ menuBar callbacks
 │   ├─ GlobalHotkey.register    ⌥⌘R; logs and continues if another app owns it
 │   ├─ NotificationRouter       set BEFORE anything posts, or a click has nowhere to go
 │   ├─ CameraWatch.startIfEnabled    opt-in; usually does nothing
 │   ├─ UpdateWatch.startIfEnabled    on by default; first check is 20s after launch
 │   ├─ observeState()            re-arms itself per change; drives the menu bar
 │   └─ transcription.resumePending   the queue is just a rescan of state.json
 ├─ DoctorReport.run         no probes — they cost ~2s and play a tone
 ├─ TempSweep.run            reclaim a crashed diarization's scratch files
 └─ SetupWindowController    shown only if the models are missing
```

**Windows, and who owns them.** `MeetingPanelController` → three `NSWindow`s (pill, recording,
wrap-up); `HistoryWindowController` → Meetings; `SettingsWindowController` → Settings;
`SetupWindowController` → Setup & Checks. Everything readiness-related renders `DoctorReport`,
which has exactly one full renderer — that window (§2). `MeetingPanelController` and
`HistoryModel` are **two surfaces over one object** — both conform to `MeetingDetailModel` and
share the detail view *and* the summarize path (§4).

**The folder is the database.** No index. `.plume/state.json` is simultaneously the durable stage
machine and the work queue, so `resumePending()` at launch just rescans; `MeetingLibrary` lists
history by reading the first 4 KB of each `meeting.md`.

**Three isolation domains, chosen per layer**: `@MainActor` for `AppController`, `AppState`,
`RecordingSession` and all UI; actors for `TranscriptionCoordinator`, `ParakeetEngine`,
`OfflineDiarizer` and `SummaryEngine` (they own non-`Sendable` model managers and serialise long
work); `OSAllocatedUnfairLock` in `MicRecorder`/`SystemAudioRecorder`, where callbacks are
real-time and an actor hop is not available.

## 1. Invariants — breaking these destroys something unrecoverable

Audio is deleted after transcription, so most damage here cannot be undone.

1. **Never silently rewrite a marked region.** `meeting.md` has `<!-- plume:notes -->`,
   `<!-- plume:summary -->`, `<!-- plume:transcript -->`. Re-read from disk before every write,
   replace only between markers, and **fail loudly if a marker is missing** — never append a
   duplicate. Writes go through `FileManager.replaceItemAt`, never `Data.write(.atomic)`, which
   swaps the inode and drops xattrs and Finder tags. The version-skew case of the same rule:
   every write path calls `MeetingDocument.checkWritable` and **refuses a document whose
   frontmatter `plume:` declares a format newer than this build**. Add a write path, add the
   check — `SpeakerEditing.apply` is the one that composes `replacing` + `write` itself and so
   needs its own call. Tolerance runs one way only: older and missing are fine, newer is not.
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
| Setup and diagnostics are one window | Merged 2026-08-16. They asked the same six `DoctorReport` checks, and the split had already produced two readings of one probe. `DoctorReport` is the engine and the window is its renderer. Probes stay behind a button (~2 s, plays a tone), and the window auto-opens only when the models are missing. The one thing that differs between its two entries is a closing CTA shown **only** on the launch-opened instance — from Settings it is a diagnostics window, where "you can close this now" says nothing. It is a parameter of the showing, not of the window, and it is guidance rather than a step: still a window, not a wizard. |
| No transcript view in the app | Deliberate. The transcript is summarizer input and text in `meeting.md`. Speaker rows show sample lines so you can identify a voice without one. |
| Notes have no automatic timestamps | Reversed in Phase 5: stamps went stale whenever a line was edited, and most notes aren't anchored to a moment. ⌘T inserts one on purpose. |
| Summarizing is manual | The wrap-up gate is the point — you add final thoughts *then* summarize. A meeting resting at `transcribed` forever is normal. |
| Only four templates, no template editor | Templates are markdown files in a folder; editing one means opening it. A JSON store and an editor UI were both declined. |
| No in-app markdown editor | Declined. The files are markdown in a folder and every Mac has a good editor. |
| The panel opens on Notes but Meetings opens on Summary | Deliberate, not an inconsistency. The panel is where you *write* a record; the window is where you *read* one. Fixed per surface, never per meeting — a default that varied with the selection would make the tab jump as you scroll the list. |
| Summarize sits below the tabs, not inside Notes | So the default tab isn't load-bearing: the action stays reachable from either tab. It also leaves the bottom edge free for a future per-meeting Ask tab. |
| A recording starts as the pill, and both expanded modes share one resizable frame | Reversed together. Two fixed sizes (340×300 recording, 430×580 wrap-up) assumed a live call wanted a smaller footprint — moot once the panel is only on screen when you deliberately open it. Collapse and expand must **pivot on the same corner**, or a round-trip drifts the pill by the difference in size. Top-right is only the *preferred* corner: `PanelAnchor` flips an axis when expanding from it would run off the screen, and the chosen corner is stored until the next expand — re-deriving it at collapse time is what makes the pill wander (covered by `PanelAnchorTests`). |
| Two echo settings, not one | Different points in the pipeline and not interchangeable: `transcript_echo_filter` removes duplicates from the finished transcript (safe, default on), `mic_voice_processing` stops the echo reaching the recording but makes macOS duck all other audio for the whole meeting. Presented together, weaker one first. |
| No UI for the vocabulary file, and it cannot fix the transcript | Both deliberate. `Vocabulary.md` is a markdown file beside `Templates/` — same premise, edited in your own editor. And it is read at *summary* time: Parakeet exposes no biasing hook (FluidAudio's `vocabulary` is the model's own token table), so a misheard term is already in the transcript, whose audio is gone. The glossary makes the **summary** spell it right; rewriting the transcript from it was rejected as invariant-1 territory. |
| No Dock icon, and windows aren't in ⌘-Tab | Accessory apps are absent from ⌘-Tab **by rule**, not by window configuration — the only lever is `NSApp.setActivationPolicy(.regular)`, which brings a Dock icon and a real menu bar. Declined 2026-08-15. Windows are reached from the menu bar. |
| `state.json` carries a `machine` id, and `resumePending` skips foreign sessions | For the case where the meetings root is a *synced* folder shared by two Macs. Looks like dead code on a single Mac — `isOwnedByThisMachine` is always true there, including for pre-stamp sessions, which is why it's `String?`. Without it the second Mac adopts the first's `recorded` session and transcribes audio that may still be downloading, then deletes it (invariant 6). Only the unattended path is guarded; recording enqueues its own session directly. The id lives beside `config.json`, never in the meetings root — it must not sync. |
| Nothing in the app helps you disclose the recording | The remedy is the **visible indicator** and nothing more. A Disclosure button that copied a suggested line was built and removed the same day: consent law is jurisdictional and situational, so a canned sentence in a menubar app is either redundant for someone who knows their obligations or falsely reassuring for someone who doesn't — and the second failure is the one that matters. Working out how to get consent is the user's, not Plume's. |
| The update check never updates anything, and says nothing when it fails | It sets one field; the menu bar shows a line **only** while an update exists, and clicking it opens the release page — no appcast, no EdDSA key, no self-replacing bundle. Unreachable, rate-limited and up-to-date collapse to one answer (nil) on purpose, and **anything unparseable must mean silence** — a suffixed tag (`0.2.0-rc.1`) is refused rather than ranked, because the failure mode of guessing is a permanent un-dismissable "update available". It is the **only** non-localhost request Plume makes besides the first-run model download, so `update_check` gates the *request*: off means none is constructed, and there is deliberately no "check anyway" button to weaken that. Touching any of this puts the README's what-leaves-the-machine claim in scope. |
| `expected_participants` defaults to 2 | 1:1 is the modal meeting; the cap makes over-splitting one voice structurally impossible. Confirmed on a real 1:1 2026-08-17 — one remote speaker, no over-split. Fix a mis-split with this, **never** by lowering the diarizer threshold. |
| The recording panel's participant menu writes nothing to config | Deliberate, and it is what makes the count revert on its own. The override goes into that session's `meta.json` and nowhere else, so the *next* meeting reads `Config` because its folder has no override — there is no reset logic, no expiry and no sticky state, because there is nowhere for the value to persist. Absent key = pre-feature session = default-was-fine, correctly one case. The window it is editable in is real, not cosmetic: `stopSession` enqueues transcription immediately, so the cap is read at Stop — which is also why the control is on the recording panel and **not** in wrap-up, where it would silently do nothing. |

Genuinely **not built yet** (different thing): Ask — scoped as its own **global** surface with
the per-meeting tab as the N=1 case, not a row and not only a tab. Its four open calls are already
taken in [docs/DECISIONS.md](docs/DECISIONS.md).

## 3. Build & run

```bash
swift build && swift test                      # library + 187 tests
./build-app.sh release run                     # assemble, sign, install, launch
./build-app.sh release notarize                # release: notarize, staple, dist/Plume-<v>.zip
./.build/debug/plume diarize <file.caf>        # dev: print diarizer turns
./.build/debug/plume summarize <session-dir>   # dev: summarize in place
```

**Those two are the whole CLI, and readiness checks must not join them.** Both work on a file you
already have, with no TCC involved. A capture check run from a terminal is attributed to the
*shell*, so its answer says nothing about Plume.app in either direction — Setup & Checks is the
only honest surface for it. Runtime log: `~/Library/Logs/Plume/plume.log` (rotates once at 1 MB);
per-session transcription logs stay in `.plume/transcribe.log`.

**Releasing is: `./build-app.sh release notarize`, then attach `dist/Plume-<v>.zip` to a GitHub
release.** No Homebrew cask, no tap — a second repo and a checksum ritual to save a drag-and-drop.
**Verify the zip you actually published**, not the copy in `/Applications` — `notarize` stages in
`/tmp` and never installs, so `spctl` on the installed bundle proves nothing about what a stranger
downloads.

**The Developer ID private key is a live liability.** `Developer ID Application: SYLVAIN J R
LAFITTE (324ZRWQHHV)`, exported to `.p12` and stored 2026-08-16. That backup is what stands between
a lost keychain and re-signing every future release with a *different* certificate — which resets
TCC permissions for everyone who installed the previous one. Developer ID certs are also capped at
5 per team. The notarization team id (324ZRWQHHV) is **not** the development cert's (99VBSLFB4T).

**CI (`.github/workflows/ci.yml`) runs only what a clean runner can prove**: `swift test` plus a
debug `build-app.sh` (ad-hoc signed, since there is no certificate there — a path that silently
did not work for CI's first five runs, because `set -euo pipefail` turned the identity-detection
`grep` finding nothing into an abort *before* the ad-hoc fallback; every `grep` in that script
that is allowed to match nothing needs its `|| true`). Everything involving
capture, models, Ollama or notarization stays a manual check — a red X that means nothing is worse
than no check. It clones with `fetch-depth: 0` deliberately, so the `CFBundleVersion` stamp is a real
commit count rather than the shallow clone's `1`.

**Never test audio capture with `swift run`; the result is meaningless either way.** A bare
binary has no TCC identity — capture is attributed to the *responsible process*, i.e. your
terminal. Without that grant you get full-length silence with no error; with it, capture works
while proving nothing about the app. Both were observed hours apart from one binary. Only the
`.app` has a self-owned grant.

**`CFBundleVersion` is stamped by the build, not by hand** — `git rev-list --count HEAD`, applied
with PlistBuddy to the *staged* plist so the repo's copy stays the hand-set
`CFBundleShortVersionString` only. v0.1.0 shipped with it stuck at `1`, and nothing caught it:
codesign, notarization and Gatekeeper are all indifferent, so the failure lands later and elsewhere
(LaunchServices not seeing an update as newer). Don't reintroduce a hand-set value.

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
`styleMask`, which cannot be mutated after init (do it anyway and typing silently stops working).
`.titled` is needed to become key so you can type while a call stays frontmost, but it carries an
invisible ~28pt titlebar: below that height `contentLayoutRect` collapses to **zero** and SwiftUI
lays content out below the visible window. Hence the 22pt pill is `.borderless`. And **wrap-up is
an ordinary `NSWindow`**, not a floating non-activating panel: the reasons to float expire at
Stop, and more importantly a `.nonactivatingPanel` can be *key while another app is active*, where
⌘C reaches nothing — key equivalents route through the **active** app's main menu. Wrap-up is
where a summary gets copied out, so it cannot be that kind of window. Level and
`collectionBehavior` *are* safe to mutate; `styleMask` is not, which is why this is a third window
rather than a mode.

Four more rules the panel depends on, none of them enforced by anything:

- `isMovableByWindowBackground` must stay **off**. On, any drag on content moves the window,
  which silently breaks drag-to-select and swallows drags on the pill. Headers and the pill
  carry an explicit `WindowDragGesture()` instead.
- The pill is **not a `Button`** — a Button treats a drag as a click, so it expanded whenever
  you tried to move it. Plain view + drag gesture + tap gesture.
- The hosting view overrides `acceptsFirstMouse`, and the recording panel calls `makeKey()`
  *without* `NSApp.activate`. A non-activating panel isn't key until clicked, so otherwise the
  first click only raises it and the second reaches the field — and `@FocusState` cannot focus
  anything in a window that isn't key.
- `hosting.sizingOptions = []`, or SwiftUI's intrinsic size snaps the window back after every
  resize. **Window metrics generally lose to the hosting view:** `minSize`/`contentMinSize` are
  set and still ignored once it is installed, so the floor is enforced in `windowWillResize` —
  the one point AppKit asks before committing a drag.

**Notifications must be posted *and* routed.** `osascript -e 'display notification'` posts as
**Script Editor** — so clicking one opens Script Editor, not Plume. That was the right trade
before the app had a bundle; now `Notify` uses `UNUserNotificationCenter`, keeping osascript only
for the bundle-less dev subcommands. And the API alone is not enough: with no delegate macOS merely
*activates* the app, which for an accessory app means fronting whatever window exists — a
"you aren't recording" reminder opened **Settings**. `NotificationRouter` sets the delegate and
registers the category *before* anything can post.

**`fixedSize(horizontal:false, vertical:true)` belongs on text that must wrap, never on a
container that must scroll.** Both failures shipped on the same day: on the Settings *container*
it forced the window past the bottom of the screen with no scrollbar (nothing is ever clipped, so
nothing scrolls); missing from the setup window's `Text`s, SwiftUI compressed each to one clipped
line.

**The three hand-editable stores share one cache and one test hook.** `Config`, `TemplateStore`
and `VocabularyStore` all sit behind `MTimeCache`, keyed on the *files'* own mtimes — a
directory's mtime moves only when an entry is added or removed, so a directory-keyed cache would
ignore the in-place edit that is the whole premise of the folder. Their path overrides
(`Config.withPath`, `TemplateStore.withDirectory`) are `@TaskLocal`, **not locks**: a lock is
process-wide, and Swift Testing runs in parallel, so one test's temp path became another suite's
answer. Both rules are covered by `InjectablePathsTests`; reasoning lives at `Config.pathOverride`
and in `MTimeCache`.

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
`initialTab`, and `summarizingFinished(session:)` — the panel retires the meeting to history,
history rebuilds its list.

**`SummaryEngine.summarize` returns the session URL, and callers must use it.** Deriving a title
renames the folder. Both surfaces used to find the new one by matching the `yyyy-MM-dd-HHmm`
prefix, which two meetings started in the same minute share — `RecordingSession` disambiguates
with a `-2` suffix and `renameFolder` drops it — so a surface could silently follow the *other*
meeting. Back-to-back calls are a designed-for case, not an edge one.

**`SummaryEngine` holds no `OllamaClient`.** It is built at launch, so a stored client pins the
model configured then, while Settings and the readiness caption both report the current
one — and the wrong name gets stamped into `meeting.md` as provenance. One client per
`summarize()`: current on each run, and *fixed* between `stream()` and `unload()`, or a
mid-generation config change would evict a model Plume never loaded.

**Swift 6 strict concurrency is on.** `OfflineDiarizerManager` isn't `Sendable` and needs an
owning actor. Don't reach for `@unchecked Sendable`: use a lock. The three that exist each carry
a justification, and `MicRecorder`'s is **inherited debt** — Quill disabled checking on the whole
class; quill#18 locked the fields that raced but the conformance still hides anything new.

**Pipeline state** is `.plume/state.json`: `recorded → transcribed → summarized`, plus
`failed(stage,message)` / `needsPermission` / `cancelled`. Only transcription resumes
automatically, and blocking must preserve the stage reached — otherwise a meeting whose audio is
gone gets re-transcribed into nothing. It also carries a `version`: `isReadyForWork` is false for
anything newer than `SessionState.formatVersion`, so a session written by a future Plume is left
alone rather than transcribed against a stage machine we're guessing at — the first thing that
happens to a `recorded` session is that its audio is deleted. `nil` means pre-versioning and is
tolerated, exactly like `machine`. **Both format versions are bumped only when a change would make
this build misread a newer file** — adding a key that older builds ignore does not qualify.

## 5. Working habits

`spikes/` keeps **results only** — the throwaway projects were deleted once each finding had
graduated into shipping code. Layout is in §0.

`upstream` points at digimata/quill; we cherry-pick from its open PRs and **attribute them in
the commit message**. Upstream merges almost nothing, so don't expect to pull. Note the PRs are
mutually unaware: combining two correct ones has twice produced a bug.

**Because that remote exists, `gh` with no `--repo` resolves to digimata/quill, not this fork** —
`gh repo view` returns *quill's* description and visibility. Harmless while reading, public and
embarrassing for anything that writes: always spell out `--repo sylvainlafitte/Plume` on
`gh release`, `gh issue` and `gh pr`.

Match Quill's voice — small files, comments explaining *why* a non-obvious thing is done. No new
dependencies without a comment at the point of use saying what they replaced.

**This repo is deliberately under-scaffolded for its size**, and a round of removals on
2026-08-17 made it more so. Distribution channels, running logs, plan registries and kill switches
each serve a stranger, a future version or a second maintainer — none of which this project has.
**Before adding machinery, name the person it is for.**

**When a bug survives one plausible fix, stop guessing and measure.** Three "fixes" went into a
clipped panel before one diagnostic printed the geometry and found it in seconds.

## Keeping this file current

*Last reviewed against the code: 2026-08-17, after the trim (cask, plan/progress docs, CLI
checks, `on_stop`, `transcription.enabled`, update-check "Check now").*

**Update it in the same commit as the change, never "later."** A separate documentation pass does
not happen, and a silently wrong constraint is worse than a missing one — the next agent will
trust it. Bump the date when you edit; if it is far behind HEAD, spend five minutes checking
sections 1 and 4 against reality before trusting them.

**The same rule covers README.md, and there it is public.** Every claim in it is checkable against
the app in a minute, and none of them fail to compile when they go stale: install commands,
permissions, config keys and defaults, on-disk paths, the uninstall list, the feature list. A
change to any of those is a README change in the same commit. Three it must never be wrong about,
because each costs trust rather than time: **what leaves the machine** (localhost Ollama, the
first-run model download, the daily release check, and nothing else), **that audio is deleted
after transcription**, and **anything named as not yet built** — Ask stays listed as
designed-not-built until it ships.

**The test for belonging here** is not length, it's: *would getting this wrong cost more than
reading it?* Irreversible damage and reversed decisions always qualify. A platform trap qualifies
while it stays invisible — once a test or an obvious code comment enforces it, cut it here and
keep the pointer. Dead ends belong in DECISIONS.md; anything derivable from reading the code
belongs nowhere. §0 is the exception that proves it: the shape *is* derivable, but only by reading
a dozen files, and every session needs it.
