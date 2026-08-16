# Plume — design record

**What this file is.** The registry for the `F*` (findings) and `R*` (risks) numbers cited from
comments in `Sources/` and from AGENTS.md. It is a *pre-implementation* record: where it and the
code disagree, **the code is right** and this is history.

It used to be the full 750-line plan — context, phasing, acceptance criteria, verification steps.
All of that is either shipped, superseded, or logged with its outcome in
[PROGRESS.md](PROGRESS.md); it is in git history if you need it. What survives here is the part
that is still *referenced*: the numbered findings and risks, at the resolution a code comment
citing one actually needs.

Measurements live in [spikes/](../spikes/), each with a RESULTS.md that re-runs.

---

## Findings

**F1 — `OfflineDiarizerManager`, not the streaming diarizer.** We have complete files on disk, so
there is no reason to pay LS-EEND's error rate. FluidAudio's own AMI-SDM benchmarks:
`OfflineDiarizerManager` (pyannote community-1 + VBx) **10.6% DER, unbounded speakers**;
`LSEENDDiarizer` 20.7%, capped 4–10; `OfflineSortformerDiarizer` 56.7% — a trap on long
multi-speaker audio. Models are 21.4 MB, CC-BY-4.0, no HuggingFace token.

Settings are **measured values, not preferences** (live in `DiarizationEngine.swift`):
`clusteringThreshold: 0.7` (the 0.6 default undercounts, degrading to 15.5%), but 0.7 was tuned
on 4-speaker AMI and over-splits a 1:1 — cap with `withSpeakers(max:)` instead of lowering it;
`segmentationStepRatio: 0.1` + `minSegmentDuration: 0.0` (15.07% → 13.89% on VoxConverse at half
throughput — free accuracy for batch); `zeroVoteReembed(enabled: true)`, without which zero-vote
frames tie-break to cluster 0 and silently absorb whole speaker turns.

**F2 — Parakeet stays on `.v2`.** FluidAudio 0.15.5 defaults to `.v3` (25 European languages,
acoustically inferred); v2 is better on English (2.1% vs 2.5% WER). Omitting `version:` silently
changes the model. Required model set is 464 MB.

**F3 — Ollama: native `/api/chat`, never `/v1`.** Three separate facts. (a) Ollama picks
`num_ctx` by VRAM tier — on a 16 GB Mac that is **4096**, i.e. the tail of a meeting only.
(b) `/v1` has no `options` passthrough, so `num_ctx` is unsettable there; Ollama's own
compatibility docs say so. (c) `truncate`/`shift` both default true and silently drop the front —
send them **false** so overflow becomes an HTTP error carrying the token counts.

Revised by [Spike C](../spikes/num-ctx/RESULTS.md): gemma4's KV cache is 16 KiB/token (only 4 of
42 layers carry a full-context cache), so 32768 costs **552 MiB** and generates at 33.6 tok/s,
100% GPU. Hence `num_ctx: 32768` — a 1-hour meeting is ~15k tokens and summarizes in a single
pass. Map-reduce stays implemented as the fallback past ~2.5 hours, which is what keeps the
no-silent-truncation guarantee true at any length.

**F4 — Floating panel configuration.** *Largely superseded — see AGENTS.md §4, which describes
what actually shipped.* This described one `.nonactivatingPanel` with `.titled`
(load-bearing: it becomes key so you can type while the call stays frontmost) and warned never to
mutate `styleMask` after init. Implementation split it into **three windows**: the pill is
borderless (a `.titled` window's `contentLayoutRect` collapses to zero below ~28pt), and wrap-up
is an ordinary `NSWindow` (a non-activating panel can be key while another app is active, where
⌘C reaches nothing).

[Spike B](../spikes/panel/RESULTS.md) confirmed keystrokes land in a SwiftUI `TextField` while
another app keeps frontmost status, and **corrected** the claim that `sharingType = .none` no
longer hides windows from screen shares — measured on macOS 26.5.1, it still works. Apple
declines to *guarantee* exclusion as a security boundary; that is not the same as it failing.
Keep it, and still make no privacy promise in UI copy.

Accepted cost: while the panel has keyboard focus, Zoom's in-meeting shortcuts do not fire.

**F5 — Camera detection.** `kCMIODevicePropertyDeviceIsRunningSomewhere` on CoreMediaIO video
devices reports camera-on with **no TCC permission and no green dot** — a status read, not a
capture. Built 2026-08-16 as `CameraWatch`, exactly as described.

*The finding did its job only by accident: it was re-derived from scratch with a throwaway probe,
because nothing outside this document pointed at it. If you are about to spike a macOS API, grep
this file for it first.*

**F6 — ASR↔diarization alignment is a data-model change, not a helper.** FluidAudio deliberately
doesn't compose the two, and the work is larger than it looks: Quill's `TranscriptSegment` is
`(start, end, text)`, and `segments(from:)` groups up to **60 words** before discarding the
`WordTiming`s — a 60-word segment routinely spans a speaker change. So word timings must be
plumbed through the `TranscriptionEngine` protocol and segments re-cut at diarization boundaries,
per word, rather than labelled after the fact.

**F7 — Notes are saved whole on a 1.2s debounce.** One `TextEditor` in every state, not a
markdown editor: no preview, no highlighting, no toolbar.

**F8 — The panel is the whole post-meeting flow, and summarization is gated on a human.**
Stopping the recording does not end the interaction: the panel stays up and expands so final
thoughts can be added while transcription runs, and only then is the summary generated.

```
[pill]       62×22 capsule: red dot + elapsed. Click to expand.  ⌘M collapses
     ↕
[recording]  elapsed, Stop, notes editor, ⌘T timestamp
     ↓ stop
[wrap-up]    Notes (editor + template + Summarize) │ Summary (result + speakers)
     ↓ transcription + diarization finish in the background
[ready]      Summarize enabled → streams into the Summary tab
```

Three consequences: summarization is a **separate human-triggered stage**, so `meeting.md` is
written as soon as transcription finishes with `## Summary` reading `*pending*` — a failed Ollama
call must never leave the transcript unwritten, and summarizing is then always
*replace-a-region-in-an-existing-file*, the same operation as regeneration. Notes are editable
**throughout**, not just at wrap-up (the original append-only design was wrong in use: you
rewrite notes as a meeting goes). And because the transcript is never displayed, **there is no
transcript view to build** — no long-list rendering, no virtualization, no scroll-sync. That is a
genuine simplification, not a deferral.

**Speaker correction without a transcript view**: the Summary tab lists detected speakers with
two or three representative utterances each, supporting rename, **merge**, and drop-to-`them`.
Merge is not polish — diarization's characteristic failure is splitting one person across two
labels, which rename alone cannot repair. *Declined: a full read-only transcript view with
search.*

**F8a — Summarize is pinned below the tabs, and each surface opens on a different tab.** Putting
the action inside Notes made the default tab load-bearing — it decided whether the action was
reachable at all. Pinned below, the default can simply follow what each surface is *for*: the
panel opens on Notes (you are writing a record), history on Summary (you are reading one back).
Fixed per surface, never per meeting, or the tab jumps as you move down the list.

**F9 — Templates are markdown files in a folder, not a JSON store.** The file body *is* the
system prompt; frontmatter carries the display name. The picker just lists the folder and "Open
Templates Folder" is the entire editing UI. This deletes OpenOats' `templates.json` + built-in
reconciliation + `resetBuiltIn` machinery (~200 lines). Seeds are written only when missing, so
hand-edits survive updates. In Application Support rather than `~/Meetings/Templates/`, so the
meetings folder stays purely meetings.

**F10 — Settings is a small window; the config file stays authoritative.** The window reads and
writes the same `config.json` — one store, not two, so a hand-edit and a UI edit can never
disagree. Deliberately *not* exposed: diarizer threshold, step ratio, overlap and quality gates.
Those are measured values with reasons recorded in code, and a wrong one produces a subtly bad
transcript that cannot be redone (R3).

**F11 — ~~Ask is a row, not a surface.~~ Reversed: Ask becomes a tab.** The original argument was
that a tab living only in the post-call panel would be in the wrong place for old meetings —
sound while the panel and history window were separate implementations. Extracting the shared
`MeetingDetailView` dissolved it: a tab now appears in both surfaces automatically. Ask is a mode
you stay in, not a control you press once.

*Since re-scoped again — see PROGRESS.md, "Road to public, and to Ask": Ask is its own **global**
surface, with the per-meeting tab as the N=1 case. Still not built.*

**F12 — Derive the meeting title and speaker names from notes + transcript.** Recording starts
before anyone knows what the meeting is about, so the folder is created as `2026-08-13-1402` and
renamed once a title exists. Signals, strongest first: self-introduction ("Hi, I'm Marie"), a
vocative aimed at the far end ("Thanks, Tom"), turn adjacency after a direct address, and names
in your notes — the last tells you *who was there*, not who spoke when.

Folded into the summary call as **schema-constrained structured output**, which also bounds the
injection surface: a response that must match a schema cannot wander off into whatever someone
said aloud. **Proposals, never silent rewrites** (invariant 3): a wrong name attributes quotes to
a real person who didn't say them.

---

## Risks

| | Risk | Mitigation as built |
|---|---|---|
| **R1** | **FluidAudio breaks APIs in patch releases.** v0.14.4 broke LS-EEND constructors and reverted inside one release; `SpeakerManager` flipped actor→struct across two patches; v0.15.5 removed `DownloadUtils`. No CHANGELOG | Pin `.exact("0.15.5")`; wrap every call behind our own protocol so a bump is a one-file diff. Treat bumps as compile **plus** a DER re-run on the corpus |
| **R2** | **Diarization accuracy is the highest-variance component.** 10.6% DER is AMI-SDM — a proxy, not a guarantee for VoIP | Per-segment confidence gate falls back to `them` rather than guessing. Rename **and merge** are the human fixes. Test the 1:1 case explicitly (F1) |
| **R3** | **No audio means no re-runs.** Deleting immediately is a requirement, so a meeting with mislabelled speakers or a silent mic track is simply lost | Tune only against a **held-aside corpus** kept outside the pipeline — never against a real meeting. Also: "deleted" is a retention policy, **not secure erasure** — audio may survive in Time Machine, APFS snapshots or a synced folder, so `.plume/` must be excluded if `~/Meetings` ever lands in iCloud Drive |
| **R4** | **Consent and legal exposure.** Recording a private conversation without participants' knowledge is a criminal offence in France (Code pénal art. 226-1) and in US two-party-consent states | The **visible recording indicator**, and nothing more. A Disclosure button that copied a suggested line was built and removed the same day — see AGENTS.md §2 |
| **R5** | ~~16 GB is tight.~~ **Largely defused for summarization** ([Spike C](../spikes/num-ctx/RESULTS.md)): weights + cache ≈ 10.2 GB against a ~11.5 GB working set. The remaining risk is *sequencing*, not context size | Release ASR and diarizer models before summarizing: transcribe → diarize → `release()` → summarize → unload **our** model with `keep_alive: 0`. Never evict other apps' models — Ollama is shared |
| **R6** | **Mic capture dies when a call app takes the input device** — the core use case, not an edge case. A 19-minute FaceTime call produced a **1.7-second** mic track, silently | Restart on `AVAudioEngineConfigurationChange` with a 0.5s debounce, re-attaching to the same file and zero-padding the dead span so timestamps stay wall-clock true; plus a size-poll watchdog. Also observe `NSWorkspace.willSleepNotification` |
| **R7** | **First run downloads ~486 MB lazily inside `prepare()`** — i.e. after the first meeting ends, on whatever network, with no progress UI | Pull models from the setup window with FluidAudio's `progressHandler`, before they are needed. Never discover a missing model after an important meeting |
| **R8** | **Temp-disk surprise.** Diarization converts the whole track to 16 kHz mono float32 in `temporaryDirectory` before mmapping — ~460 MB for a 2-hour meeting, leaked if it crashes mid-run, and macOS clears `/var/folders` on its own schedule | `TempSweep` at launch as well as on completion. Deliberately narrow: FluidAudio's own naming, and only files old enough that no live run could own them |
| **R9** | ~~Echo suppression may be solving a solved problem.~~ **Resolved: real and severe.** **477 of 641 "me" segments** in a 42-minute meeting were echoes of far-end speech, reaching the mic *louder* than the author's own voice (−33.9 vs −37.6 dBFS) | Word-level LCS, ≥70% in-order containment, ±400 ms pad, exact-match-only for 1–2 word segments so backchannels survive. Log drop counts; never drop silently |
| **R10** | **A human-gated summary is a summary that may never happen** — the cost of F8's wrap-up gate | Nothing is ever *lost*, only un-summarized: `meeting.md` exists with a full transcript from the transcribed stage onward. Surface pending meetings; never block on the gate |
| **R11** | **Wrap-up competes with the next meeting.** Back-to-back calls mean stopping one recording while the next starts; a panel demanding attention is exactly wrong then | Starting a new recording must never block on an unfinished wrap-up. The previous meeting drops to pending and is picked up from the list |
| **R12** | **The system tap is global** — it records notifications, music and every other app, so a Slack ding mid-sentence corrupts a segment | `CATapDescription` supports per-process and exclusion forms. A "call audio only" mode remains possible; not built |
| **R13** | **Speaker IDs are only consistent within one diarization run.** If a recording is ever split, `S1` in segment 1 is unrelated to `S1` in segment 2 | Keep the system track as a single file — R6's restart re-attaches rather than starting a new one. If a split is ever unavoidable, stitch with `speakerDatabase` embeddings, never by trusting labels |
| **R14** | **Auto-derived speaker names can be confidently wrong**, and a wrong name is worse than an honest `S1` | Proposals only, never applied automatically (F12, invariant 3). Show the evidence span, propose nothing below a confidence floor, require one click |
| **R14b** | **Audio present but too quiet to transcribe.** Found 2026-08-14: input volume at 29/100 put speech at −31 dBFS — clearly speech, clearly too quiet. Every other safety net checks for the *absence* of audio; none catches a weak signal, and with audio deleted (R3) the meeting cannot be redone | A **level** check, not just a presence check: sample the input and warn below a peak threshold. Report dBFS, not a bar graph — the number is what makes it actionable |

**B3 — System-audio capture depends on being its own responsible process, and fails silently.**
The finding that most threatened the plan, and the origin of invariant 5. Launched from a shell,
`AudioHardwareCreateProcessTap` returns `noErr`, the format is correct, the aggregate device is
created, `AudioDeviceStart` succeeds, the IOProc fires at exactly the right rate — and every
sample is zero. TCC attributes the request to the *responsible* process, which from a terminal is
the terminal. Resolved by shipping a real `.app`; measured in
[Spike A](../spikes/responsible-process/RESULTS.md).

This is also what gives `doctor` a real job: there is no side-effect-free API to query
system-audio TCC state, so the only trustworthy check is empirical — play a tone, capture, assert
the buffer isn't all zeros.

---

## Upstream PRs worth harvesting

Quill has 14 open PRs and one merged (a README link fix). Community work is not being taken
upstream, which reinforces the fork decision. All are MIT by the repo's terms — **attribute them
in the commit message**. Note the PRs are mutually unaware: combining two correct ones has twice
produced a bug.

| PR | What it gives us |
|---|---|
| [#54](https://github.com/digimata/quill/pull/54) | System audio is all-zero silence unless quill runs as a LaunchAgent — the report behind B3 |
| [#2](https://github.com/digimata/quill/pull/2) | Mic restart on `AVAudioEngineConfigurationChange`, re-attaching to the same file and zero-padding the dead span (R6) |
| [#25](https://github.com/digimata/quill/pull/25) | Transcript-level echo filter: word-level LCS, ≥70% containment, ±400 ms pad (R9) |
| [#20](https://github.com/digimata/quill/pull/20) | Diarization via offline Community-1/VBx with a per-segment confidence gate falling back to `them` — independent arrival at F1/F6 |
| [#6](https://github.com/digimata/quill/pull/6) | Liveness watchdog: 15s file-size poll, 45s stall → notification. 54 lines |
| [#18](https://github.com/digimata/quill/pull/18) | `OSAllocatedUnfairLock` around the cross-thread recorder fields — the fix for the `@unchecked Sendable` debt |
| [#7](https://github.com/digimata/quill/pull/7) | Write the completion marker **last**, so a failed later write leaves the session pending |

Not needed: #52 (Whisper), #3 (AssemblyAI, cloud), #55/#4/#9 (Parakeet v3 / language selection —
English-only per F2), #53/#12 (release tooling). #16, #17 and #18 fix the same data races and
#24/#25 are duplicate echo filters — take the most recent of each.
