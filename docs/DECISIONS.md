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
