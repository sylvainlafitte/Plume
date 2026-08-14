# Progress

Living log. [docs/PLAN.md](PLAN.md) holds the design and the reasoning behind it; this file
holds **what has actually happened**, and — the part that matters most across sessions — what
was tried and rejected, so nobody re-runs a dead end.

---

## Current state

**Phase:** 0 — scaffolding
**Next action:** Phase 1 spike A (responsible-process / system-audio go-no-go). Nothing else in
Phase 1 is worth building until it has an answer.
**Blocked on:** nothing

---

## Phase checklist

### Phase 1 — Spikes, then fork and foundations
Spikes first; **A is go/no-go for the whole packaging decision.**

- [ ] **Spike A — responsible process (B3).** Throwaway `.app`, launched from Finder, records
      2s of system audio while a tone plays; assert samples are not all zero. If a bundle does
      *not* get its own TCC identity, packaging reverts to a LaunchAgent and Phases 5–6 need a
      different window-owning strategy.
- [ ] **Spike B — panel.** ~40 lines AppKit: confirm the F4 style mask accepts typed text with
      Zoom frontmost; confirm screen-share exposure with a QuickTime recording (expected:
      visible — see B2).
- [ ] **Spike C — `num_ctx`.** Load `gemma4:latest` at 4096 and 16384, diff `ollama ps` SIZE.
      KV-cache cost has a 10× spread depending on SWA trimming.
- [ ] Fork Quill → Plume; rename bundle ID, binary, config path, output dir
- [ ] `.app` bundle build script; `LSUIElement`; `SMAppService.mainApp` login item
- [ ] Lift `private` transcript types to internal
- [ ] Test target
- [ ] Pin FluidAudio `.exact("0.15.5")`
- [ ] `statusHandler` → `@Observable` + menubar error item
- [ ] Settings shell (⌘,) + `Config` caching and file-watch fix
- [ ] Transcript segment shape incl. `speaker` + word timings
- [ ] Cherry-pick #18 (data races), #2 (mic restart), #6 (liveness watchdog)
- [ ] `doctor`: empirical system-audio check

**Done when:** all three spikes answered, and a menubar record from `/Applications` produces a
transcript with *verified non-zero* system audio.

### Phase 2 — Diarization and echo
- [ ] `OfflineDiarizerManager` over the system track (threshold 0.7, stepRatio 0.1,
      minSegmentDuration 0.0, zeroVoteReembed on)
- [ ] Word-timing attribution + re-segmentation on speaker boundaries
- [ ] Per-segment confidence gate, falling back to `them` (per PR #20)
- [ ] Echo filter (port PR #25)

**Done when:** on the test corpus, a 3-person call yields distinct speakers **and a 1:1 yields
exactly one remote speaker.** The second is the one expected to fail.

### Phase 3 — Markdown + stage machine
- [ ] `meeting.md` written at `diarized` with summary `*pending*`
- [ ] Marked regions, flat frontmatter, `replaceItemAt`
- [ ] `.plume/state.json` stage machine incl. `failed` / `cancelled` / `needs_permission`
- [ ] Audio deletion after transcript region written

### Phase 4 — Summaries
- [ ] `SummaryEngine` on `/api/chat` (`num_ctx: 8192`, `truncate:false`, `shift:false`, 300s)
- [ ] Map-reduce with carry-forward context between windows
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
      time no amount of coding compresses, and Phase 2 cannot be signed off without it:
  - [ ] a 1:1 (the case expected to fail)
  - [ ] a 3-person call
  - [ ] one recorded on speakers rather than headphones (for the echo filter)
  Keep these outside the pipeline; they are the only way to tune diarization once production
  audio is being deleted immediately.
- [ ] Decide the recording disclosure wording for calls (R4).

---

## Decisions made during implementation

Append here as you go. Format: date, what was decided, and **why** — especially if it differs
from PLAN.md, in which case update PLAN.md too and say so.

| Date | Decision | Why |
|---|---|---|
| 2026-08-14 | Scaffolding: git + upstream remote, AGENTS.md, this file, `spikes/`, `.gitignore` | Multi-agent work across sessions needs revert-ability and a durable memory outside any one session |

## Tried and rejected

The most valuable section. Record dead ends **with the evidence**, so they aren't retried.

| Date | Tried | Outcome |
|---|---|---|
| — | *(nothing yet)* | |
