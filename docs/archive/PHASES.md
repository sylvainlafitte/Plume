# Phase checklist, phases 1–6

> **Closed.** Moved out of [PROGRESS.md](../PROGRESS.md) on 2026-08-16, once all six phases were
> built and the per-item detail had stopped being something anyone reads. Kept because it records
> *what was actually built per phase* — including the parts that were reversed mid-phase, which is
> the half a git log doesn't tell you. The open items were left behind in PROGRESS.md.
>
> [AGENTS.md](../../AGENTS.md) is where the current shape lives; PROGRESS.md carries state,
> decisions and dead ends.

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
      dBFS. Reachable from Settings → Diagnostics (moved out of the menu bar in Phase 6)
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
- [x] Settings pane for `expected_participants` (as "usual meeting size") and
      `transcript_echo_filter`, phrased by consequence rather than by mechanism; picker keeps a
      hand-edited out-of-range value visible instead of blanking

**Done when:** on the test corpus, a 3-person call yields distinct speakers **and a 1:1 yields
exactly one remote speaker.** The second is the one expected to fail.

### Phase 3 — Markdown + stage machine
- [x] `meeting.md` written as soon as the transcript exists, summary `*pending*`
- [x] Marked regions, flat frontmatter, `replaceItemAt` (xattr-preservation tested)
- [x] `.plume/state.json` stage machine with `failed` / `needsPermission` / `cancelled`
- [x] Audio deleted once the transcript is durably written
- [x] Layout: session folder shows only `meeting.md`; audio/meta/log/state live in `.plume/`
- [x] Folder naming `yyyy-MM-dd-HHmm` (Phase 4 appends the title slug)
- [x] Replaced the `transcript.json`-presence sentinel with the stage machine
- [x] Signed with a real Apple Development identity so TCC grants survive rebuilds

### Phase 4 — Summaries
- [x] `OllamaClient` on native `/api/chat` (`num_ctx: 32768`, `truncate:false`, `shift:false`,
      300s cold-start timeout), streaming NDJSON, `keep_alive:0` unload of **our** model only
- [x] Single pass by default; map-reduce with carry-forward digests, triggered by Ollama's
      `exceed_context_size_error` and sized from the token counts it reports
- [x] Templates as markdown files, seeded once and never overwritten (F9)
- [x] Title + speaker-name proposals via schema-constrained `format` (F12); names land in
      `.plume/proposals.json` awaiting a click, only the title is applied
- [x] Folder rename on titling
- [x] Stream-to-buffer, region replaced only on success (invariant 2)
- [x] Settings: model picker from `/api/tags`, default-template picker, open-templates-folder
- [x] `doctor`: Ollama reachability, model installed, context reported
- [x] `plume summarize <session> [--template id]` dev command
- [x] Trigger wired into the wrap-up panel (Phase 5); the CLI command remains for tuning

### Phase 5 — The panel
- [x] Recording strip (non-activating), ↩ saves a stamped note and keeps focus, hide button
- [x] Wrap-up: expands and activates on Stop; Notes (editable) / Summary tabs; summarize with
      template picker; open-in-editor
- [x] Speaker list: rename, merge, proposals shown *with their evidence*
- [x] `NotesStore` — append-with-timestamp during the call, whole-file editing at wrap-up,
      `--- after the call ---` boundary marker
- [x] **Verified live 2026-08-15:** ↩ saved notes, frontmost was not stolen, panel expanded on
      Stop, wrap-up notes were editable and reached the summary
- [x] **Round 2 (user feedback):** free-text notes with ⌘T timestamps instead of auto-stamped
      lines; wrap-up divider removed; three panel sizes (pill / strip / wrap-up) with close +
      minimise top-left in macOS order; Summarize moved to be the primary CTA under Notes;
      spinner and progress text while generating; contextual menubar item
- [x] **Round 3 (layout):** safe-area inset, picker alignment, pill clipping, resize animation,
      and intrinsic-size snap-back — all fixed; pill split into its own borderless window
- [x] **Round 4 (2026-08-15), which supersedes parts of rounds 2–3.** A recording now **starts
      collapsed as the pill** (so "notes field focused on record start" no longer applies — the
      panel isn't up), and the two expanded modes **share one resizable frame** instead of the
      three fixed sizes above. `minSize` is enforced in `windowWillResize`, because the property
      alone is ignored once a hosting view is installed. **Wrap-up became its own ordinary
      window** at normal level, so other apps can cover it once the call is over.
- [ ] Global hotkey (needs Carbon `RegisterEventHotKey`) — menubar "Show notes panel" for now

### Phase 6 — History window
- [x] `MeetingLibrary` scans the folder (frontmatter only, first 4 KB per file — the folder is
      the database, there is no index to keep in sync)
- [x] Window: list newest-first, open in editor, reveal in Finder, regenerate with a template,
      rename/merge speakers
- [x] Meetings stuck at `transcribed` are badged "no summary", counted in the sidebar footer and
      in the menu bar (R10)
- [x] **Shared `MeetingDetailView`** — the panel and the history window are one view now; they
      had already drifted (only one rendered markdown, only one had notes) within a single phase
- [x] `MarkdownText` renders the subset our templates emit; no dependency
- [x] Summarize pinned *below* the tabs, so the default tab stops being load-bearing; panel
      opens on Notes, history on Summary
- [x] "Open meetings folder" moved from the menu bar to the sidebar footer; "Run diagnostics"
      moved to Settings — the menu bar is down to five items
- [x] **Feedback round:** ⌘C/⌘V/⌘Z fixed via an invisible main menu; drag-to-select and pill
      dragging fixed by dropping `isMovableByWindowBackground`; one-click focus via
      `acceptsFirstMouse`; notes field focused on record start; "Show last meeting" removed from
      the menu bar once a meeting is summarized; Copy-summary button and context menu
- [x] **Feedback round 2 (2026-08-15):** rename (with `title_source: user`) and delete-to-Trash,
      joined in the header by Open-in-editor and Reveal so the four escape hatches sit behind one
      `⋯` menu rather than lining the header with buttons; Ollama/model status beside Summarise;
      settings pane reworked (one "Echo from speakers" section, `transcription.enabled` toggle
      removed, Reveal-config now creates the file first); UK spelling in the UI; menubar icon
      fixed to actually go red
- [x] Both menus are built by one `rowActions(for:)`, and `openInEditor`/`revealInFinder` take
      the meeting explicitly — acting on `selected` would have opened the wrong file when
      right-clicking an unselected row

### Phase 7 — Ask (optional, first to cut)
- [ ] **A third tab** in `MeetingDetailView` (Notes / Summary / Ask), so it appears in both the
      panel and the history window for free. Reversed from the original "row under Summary" —
      see PLAN.md F11
- [ ] Whole transcript in context where it fits; Phase 4's chunking when it doesn't
- [ ] Save-answer-to-notes

---

