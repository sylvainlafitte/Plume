# Progress

Living log of **what has actually happened**, and — the part that matters most across sessions —
what was tried and rejected, so nobody re-runs a dead end.

Sibling documents: [AGENTS.md](../AGENTS.md) is the source of truth for how things work *now*
and takes precedence over the plan; [PLAN.md](PLAN.md) holds the design and the reasoning behind
it, and becomes a historical record as phases land. When work here changes a constraint, update
AGENTS.md **in the same commit**.

---

## Current state

**Phase:** 2 — implemented, unverified on real multi-speaker audio
**Next action:** record the R3 corpus (1:1, 3-person, one on speakers). Phase 2's code paths
all work, but the only multi-speaker evidence so far is synthetic unit tests — the single real
recording had one speaker. Also still pending: verify #2 across a real call connect/disconnect.
**Blocked on:** nothing (the held-aside test corpus gates Phase 2's *sign-off*, not its start)

---

## Phase checklist

### Phase 1 — Spikes, then fork and foundations
Spikes first; **A is go/no-go for the whole packaging decision.**

- [x] **Spike A — responsible process (B3). PASSED 2026-08-14**, with a same-day correction:
      the bare binary measured 0/286,720 non-zero at first and 99.5% hours later, once the
      *terminal* had gained the grant. A bare binary has no TCC identity of its own; the `.app`
      is the only deterministic, self-owned grant. Packaging decision validated either way.
      → [spikes/responsible-process/RESULTS.md](../spikes/responsible-process/RESULTS.md)
- [x] **Spike B — panel. PASSED 2026-08-14.** F4 style mask accepts typed text while another
      app keeps frontmost status. **And `sharingType = .none` still works** — the `.none` panel
      was absent from a QuickTime capture while a `.readOnly` control appeared. B2 in PLAN.md
      was wrong and has been corrected.
      → [spikes/panel/RESULTS.md](../spikes/panel/RESULTS.md)
- [x] **Spike C — `num_ctx`. DONE 2026-08-14.** KV costs **16 KiB/token** (only 4 of 42 layers
      carry full-context cache): 8192 → 168 MiB, 32768 → 552 MiB. Generation verified at 32768,
      33.6 tok/s, 100% GPU. **`num_ctx` raised 8192 → 32768**; map-reduce demoted to a fallback.
      → [spikes/num-ctx/RESULTS.md](../spikes/num-ctx/RESULTS.md)
- [x] Fork Quill → Plume; rename bundle ID, binary, config path, output dir (`~/Meetings`)
- [x] `.app` bundle build script (`build-app.sh`), `LSUIElement`, ad-hoc signing
- [ ] `SMAppService.mainApp` login item — **not done**, deferred with the settings panes
- [x] Lift `private` transcript types to internal
- [x] Test target (`PlumeKitTests`, 18 tests) — required splitting `PlumeKit` out of the
      executable, since a test target can't cleanly depend on a target with `@main`
- [x] Pin FluidAudio `.exact("0.15.5")`; dropped ArgumentParser and the `unsafeFlags` plist hack
- [x] `statusHandler` → `@Observable` `AppState` + sticky menubar error item
- [x] Settings shell (⌘,) + typed `Settings` struct replacing `[String: Any]`, mtime-keyed cache
- [x] Transcript segment shape incl. typed `Speaker` + word timings; types lifted to internal;
      deterministic tie-broken merge sort
- [x] `doctor`: empirical system-audio probe + mic-level check (R14b), both reporting measured
      dBFS; reachable via "Run diagnostics…"
- [x] Cherry-pick **#18** (`OSAllocatedUnfairLock` around cross-thread recorder state +
      malformed SVG), **#2** (mic restart on `AVAudioEngineConfigurationChange`, silence-padded
      gap, rate-change-tolerant conversion), **#6** (15s size-poll watchdog, 45s stall
      notification with recovery). Ported by hand — paths and the renamed queue label meant the
      patches didn't apply cleanly.

**Done when:** all three spikes answered, and a menubar record from `/Applications` produces a
transcript with *verified non-zero* system audio.

### Phase 2 — Diarization and echo
- [x] `OfflineDiarizerManager` behind our own `Diarizing` protocol, owned by an actor
      (threshold 0.7, stepRatio 0.1, minSegmentDuration 0.0, zeroVoteReembed on)
- [x] Word-timing attribution + re-segmentation on speaker boundaries
- [x] Per-segment confidence gate (overlap ≥50%, turn quality ≥0.5), falling back to `them`;
      single detected speaker stays `them` rather than becoming a bare `S1`
- [x] Echo filter (ported PR #25, generalised to match any far-end label)
- [x] `plume diarize <file>` dev command for tuning against the corpus
- [x] `expected_participants` (default 2 = a 1:1) capping far-end speakers via
      `withSpeakers(max:)` — makes over-splitting a 1:1 structurally impossible rather than
      merely unlikely
- [ ] **Verify on the R3 corpus** — every multi-speaker path is unit-tested only
- [ ] Settings pane for `expected_participants` and `transcript_echo_filter` (config-file only
      today; participants is the one most likely to change per meeting)

**Done when:** on the test corpus, a 3-person call yields distinct speakers **and a 1:1 yields
exactly one remote speaker.** The second is the one expected to fail.

### Phase 3 — Markdown + stage machine
- [ ] `meeting.md` written at `diarized` with summary `*pending*`
- [ ] Marked regions, flat frontmatter, `replaceItemAt`
- [ ] `.plume/state.json` stage machine incl. `failed` / `cancelled` / `needs_permission`
- [ ] Audio deletion after transcript region written

### Phase 4 — Summaries
- [ ] `SummaryEngine` on `/api/chat` (`num_ctx: 32768` — Spike C, `truncate:false`,
      `shift:false`, 300s)
- [ ] Single pass when it fits; map-reduce with carry-forward context only past ~2.5h
- [ ] Templates as markdown files + seed on first run (F9)
- [ ] Title + speaker-name proposals via schema-constrained `format` (F12)
- [ ] Folder rename on titling
- [ ] Stream-to-buffer, replace only on success
- [ ] Settings pane: model picker from `/api/tags`

### Phase 5 — The panel
- [ ] Recording strip (non-activating) + hotkeys
- [ ] Wrap-up: Notes (editable `TextEditor`) / Summary tabs
- [ ] Speaker list: rename, merge, drop-to-`them`

### Phase 6 — History window
- [ ] List, open in external editor, reveal in Finder, regenerate, rename
- [ ] Surface `awaiting_wrapup` meetings

### Phase 7 — Ask (optional, first to cut)
- [ ] Input row under Summary, hosted in both panel and history window
- [ ] Chunked retrieval, save-answer-to-notes

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
| 2026-08-14 | **Concluding from Spike A that "a shell-launched binary records silence"** | Over-generalised from one measurement with an uncontrolled variable. The same binary later passed from the same shell (0% → 99.5% non-zero) once the *terminal* had acquired the grant. Correct statement: a bare binary has no TCC identity and inherits the responsible process's, so a shell run is inconclusive **in both directions**. The `.app` decision is unaffected — it's the only deterministic, self-owned grant — and the empirical check matters *more*, since launch context can't predict capture health. Same error class as the PLAN.md B2 `[verified]` tag: a real observation stated as a law |
| 2026-08-14 | Using `ollama ps` SIZE to measure memory cost | Useless — reproducibly non-monotonic for identical weights (3.2 GB @ 4096, 9.5 GB @ 8192–16384, 3.3 GB @ 32768+). Whatever it reports, it is not weights + KV. Use `~/.ollama/logs/server.log` `llama_kv_cache:` lines instead; those are exact and linear. Also: `ollama ps` columns are `NAME ID SIZE UNIT PROC% GPU CONTEXT UNTIL` — `CONTEXT` is field 7, and it's the reliable confirmation that `num_ctx` was applied |
| 2026-08-14 | Trusting a `[verified]` tag in PLAN.md that turned out to be a *citation*, not a measurement (B2, `sharingType = .none`) | Wrong on our target OS. The source was Apple DTS declining to **guarantee** capture exclusion — a statement about warranties, not about whether the mechanism functions. Spike B measured it working on macOS 26.5.1. **Lesson: when a plan claim is tagged verified, check whether someone measured it or merely found someone asserting it.** Several remaining tags are citations |
| 2026-08-14 | Reading `ls -l` permissions to diagnose an `EPERM` on files under `~/Documents` | Misleading — TCC blocks `open()` while leaving `stat()` working, so the file shows a normal `rw-r--r--` and looks like an ordinary permission bug. The distinguishing probe is: `stat` succeeds, `cat` fails, `ls ~/Documents` fails, `/tmp` fine. Fix is System Settings → Privacy & Security → Files and Folders, not `chmod` |
