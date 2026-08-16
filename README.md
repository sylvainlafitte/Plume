# Plume

Plume records your meetings on your Mac, transcribes them, and writes a summary. Everything runs
locally: no account, no upload, no server. Each meeting becomes one markdown file you can open in
any editor.

```
~/Meetings/2026-08-13-1402-pricing-review/meeting.md
```

The summary is written from your notes and the transcript together. You type notes in a small
floating panel during the call.A template decides the shape of what comes out — 1:1, stand-up, hiring, or one you write yourself.

Plume records your microphone and the call as two separate tracks, transcribes both on
device, tells the speakers apart, drops the echo of the far end from your own track, and deletes the
audio once the transcript is written. 

---


## Local only

- **Nothing is uploaded.** Recording, transcription, speaker separation and summarization all run
  here. The only network request Plume makes is to `127.0.0.1:11434`, [Ollama](https://ollama.com)
  on your own Mac. First run downloads the speech models; after that Plume works offline.
- **The folder is the database.** One directory per meeting, one markdown file inside. No index, no
  proprietary store. If Plume vanished tomorrow your meetings would read exactly as they do now.
- **The audio is deleted** once the transcript is written. A recording of other people's voices is
  the most dangerous thing on your disk, and the transcript is what you wanted.

## Built on Quill and OpenOats

Plume is a fork of **[digimata/quill](https://github.com/digimata/quill)** (MIT, © Andrew Jones),
1,303 lines that solved the hard part: a Core Audio process tap for system audio, separate mic and
system tracks, crash-safe capture, and the filesystem-as-queue design Plume still uses. Community
pull requests upstream never merged are cherry-picked here and credited in the commits — mic restart
on device reconfiguration (#2), the liveness watchdog (#6), lock-protected recorder state (#18), the
transcript echo filter (#25).

**[OpenOats](https://github.com/yazinsai/OpenOats)** by Yazin Alirhayim was the design reference,
read but not forked. It does more than Plume does, and reading it settled several questions cheaply:
untrusted-input framing for transcripts, the shape of the panel, and which of its features were
better left out.

Both depend on **[FluidAudio](https://github.com/FluidInference/FluidAudio)**, which supplies the
Parakeet speech recognition and pyannote/VBx diarization models Plume runs on device.

---

## What it does

**Recording.** Menu bar toggle or ⌥⌘R from any app. 

**Notes.** A draggable pill during the call; click to expand and type. Your conferencing app keeps
the foreground while the panel takes keystrokes. ⌘T inserts a timestamp when a note is tied to a
moment. Nothing else is stamped, bulleted or reformatted.

**Transcript.** Parakeet v2 on device, English. The far-end track is split by speaker with per-word
attribution. The echo filter removes mic segments that are really the other side coming back through
your speakers. You are always `me`;
others are `S1`, `S2`, or an honest `them` when confidence is low.

**Summaries.** A local model through Ollama, triggered by you. A title is derived and the folder
renamed to match; rename it yourself and Plume won't overwrite that. Speaker names are proposed with
the evidence behind them and applied only when you click. Rename or merge speakers, and regenerate as often as you like.

**Meetings window.** Every past meeting in one list with its summary, notes and speakers. Rename,
regenerate, open in your editor, reveal in Finder, or delete to the Trash.

**Everything else.** A setup window that downloads the models and verifies both audio permissions;
an optional reminder when your camera turns on and you aren't recording (it notifies, never
records); an optional login item; a plain-text log; an `on_stop` shell hook for your own automation.

**Coming: Ask.** A question box over your meeting history —
answered by the same local model and citing the meetings it used. Designed, not built.

---

## Requirements

| | |
|---|---|
| **macOS** | 15 or later |
| **Mac** | Apple silicon. Built and tested on an M1 Pro / 16 GB; Intel is untested |
| **Disk** | ≈700 MB of speech models, plus your Ollama model |
| **[Ollama](https://ollama.com)** | Summaries only. Recording and transcription don't need it |
| **A model** | Default `gemma4:latest` (≈9.6 GB). Any Ollama chat model works — pick a smaller one on a smaller Mac |
| **To build** | Swift 6 toolchain |

16 GB of RAM is enough. Plume releases the speech models before summarizing and unloads its own
Ollama model afterwards, without evicting anyone else's.

## Install

Download `Plume-<version>.zip` from
[Releases](https://github.com/sylvainlafitte/Plume/releases), unzip, and drag **Plume.app** to
`/Applications`. It is signed with a Developer ID certificate and notarized, so it opens normally.

Or build it:

```bash
git clone https://github.com/sylvainlafitte/Plume.git
cd Plume
./build-app.sh release run
```

That builds, signs, installs to `/Applications` and launches.

> Plume has to run as an `.app`. A bare binary from `swift run` has no permission identity of its
> own, so system-audio capture is attributed to whatever launched it and usually records full-length
> silence while reporting success. Use `swift build && swift test` for the library and
> `./build-app.sh` for anything involving audio.

## First run

1. **Launch Plume.** A feather appears in the menu bar. There is no Dock icon.
2. **Setup & Checks opens** if the speech models are missing. Press Download (≈700 MB, with
   progress). You can close it and record straight away — a meeting recorded before the models
   arrive waits for them.
3. **Press "Check capture…".** It plays a tone, records a second, and checks the samples aren't all
   zero. macOS prompts for Microphone and for Screen & System Audio Recording; grant both.

   Worth doing before a real meeting rather than during one. macOS offers no way to *ask* whether
   system-audio capture is permitted — an unauthorized tap returns success, reports a correct
   format, and delivers nothing but zeros — so capturing a tone is the only check that tells the
   truth.
4. **For summaries**, install a model and pick it in Settings:

   ```bash
   ollama pull gemma4
   ```

   Ollama starts its daemon lazily, so "Ollama isn't running" on a cold machine is normal.

## Using it

Start from the menu bar or with **⌥⌘R** from anywhere. The pill appears and the menu bar icon turns
red. Click the pill to expand it and take notes.

Stop the same way. The panel expands instead of disappearing, so you can add the thoughts you only
have once the call is over. Transcription runs behind it, roughly 30–60 seconds for an hour of
audio. Then pick a template and press **Summarise**.

Come back to anything later from **Meetings…** — same view, older meeting. Edit the notes, merge two
speakers, switch template, regenerate.

A meeting that sits transcribed and never summarized is a normal resting state. `meeting.md` exists
with the full transcript from the moment transcription finishes, so nothing is lost.

---

## On disk

```
~/Meetings/2026-08-13-1402-pricing-review/
  meeting.md          ← notes, summary, transcript
  .plume/             ← working files; audio lives here until the transcript is written
```

`meeting.md` is markdown with flat frontmatter and three delimited regions:

```markdown
---
plume: 1
title: Pricing review
started: 2026-08-13T14:02:11+02:00
template: general
model: gemma4:latest
speaker_S1: Marie
---

<!-- plume:notes start -->
## Notes
...your own words, untouched...
<!-- plume:notes end -->

<!-- plume:summary start -->
## Summary
...generated, replaceable...
<!-- plume:summary end -->

<!-- plume:transcript start -->
## Transcript
**[00:12] me:** ...
**[00:19] Marie:** ...
<!-- plume:transcript end -->
```

Regenerating replaces one region and never rewrites the file, which is what makes it safe to keep
generated text in a document you also edit by hand.

| Path | What |
|---|---|
| `~/Meetings/` | Your meetings (configurable) |
| `~/.config/plume/config.json` | Settings — hand-editable, and the only store |
| `~/Library/Application Support/Plume/Templates/` | Summary templates |
| `~/Library/Application Support/Plume/Vocabulary.md` | Your glossary |
| `~/Library/Application Support/FluidAudio/Models/` | Speech models (shared with other FluidAudio apps) |
| `~/Library/Logs/Plume/plume.log` | App log, rotated at 1 MB |

## Privacy

Plume's only outbound request is to `127.0.0.1:11434`. No analytics, no crash reporting, no account,
no remote API. The one exception is the first-run model download, which fetches CoreML bundles from
Hugging Face through FluidAudio.

Deleting the audio is a retention policy, not secure erasure: it can survive in Time Machine, APFS
snapshots, or a synced folder. If your meetings folder is in iCloud Drive or Dropbox, exclude
`.plume/`.

The notes panel is excluded from screen capture (`sharingType = .none`, measured working against a
ScreenCaptureKit recorder), and ⌘W closes it outright. Apple guarantees nothing here, so don't treat
it as a security boundary.

Transcripts and notes are framed as untrusted input before they reach the model, because anyone on a
call can say "ignore your previous instructions" out loud.

**Recording other people is your responsibility.** Plume records everyone on the call with no notice
to them and no indicator on their end. Recording a private conversation without the participants'
knowledge is a criminal offence in France (Code pénal art. 226-1), unlawful in two-party-consent US
states, and regulated in many other places. Tell people you're recording.

## Settings

The Settings window edits `~/.config/plume/config.json`. There is one store, so a hand-edit and a UI
edit can never disagree, and a hand-edit takes effect without relaunching.

| Key | Default | What it does |
|---|---|---|
| `recordings_dir` | `~/Meetings` | Where meetings are written |
| `expected_participants` | `2` | People in a typical meeting, including you. Caps far-end speakers so one voice can't be split in two. `0` leaves it unconstrained |
| `transcript_echo_filter` | `true` | Remove duplicated far-end speech from the transcript. Safe; leave it on |
| `mic_voice_processing` | `false` | Cancel echo at the microphone instead. Stronger, but macOS quietens all other audio for the whole meeting |
| `summary_model` | `gemma4:latest` | Any model in `ollama list` |
| `summary_context_tokens` | `32768` | An hour-long meeting summarizes in one pass; longer ones fall back to map-reduce |
| `default_template` | `general` | Template id, which is the filename |
| `call_detection` | `false` | Notify when the camera turns on and Plume isn't recording |
| `transcription.enabled` | `true` | Off, recordings rest un-transcribed. No UI toggle by design |
| `on_stop` | — | Shell command run with the session directory as its argument |

The diarizer's threshold, step ratio and quality gates are not exposed anywhere. They are measured
values with their reasoning recorded in the code, and a wrong one produces a subtly bad transcript
that can't be redone.

## When something's wrong

**Settings ▸ Troubleshooting ▸ Setup & checks** reports everything Plume needs and puts the fix
beside whatever isn't ready. The log is plain text — attach it to a bug report:

```bash
open ~/Library/Logs/Plume/plume.log
```

| Symptom | Cause |
|---|---|
| Only your voice in the transcript | System audio permission. Run the capture check; it's the only signal that doesn't lie |
| Everything appears twice | Meeting played through speakers. Keep the transcript echo filter on; if that's not enough, enable mic echo cancellation |
| One person came out as two | Set the meeting size in Settings, then merge the two speakers |
| Two people merged into one | Raise the meeting size |
| "Ollama isn't running" | Normal on a cold machine. Start Ollama, or run `ollama list` |
| Speech transcribed badly | Check the mic level in Setup & Checks. A quiet input degrades recognition, and the audio is gone afterwards |

## Uninstall

Turn off "Open Plume at login" in Settings, quit Plume, delete `/Applications/Plume.app`, then
remove whatever you don't want to keep:

```bash
rm -rf ~/.config/plume                                  # settings
rm -rf ~/Library/Application\ Support/Plume             # templates and vocabulary
rm -rf ~/Library/Logs/Plume                             # log
rm -rf ~/Library/Application\ Support/FluidAudio/Models # speech models
```

`~/Meetings` is not on that list. It's your data, and the audio it came from no longer exists.

Ollama and its models are separate software. Plume's entries under System Settings ▸ Privacy &
Security disappear on macOS's own schedule.

---

## Working on Plume

```bash
swift build && swift test        # library and tests
./build-app.sh release run       # assemble, sign, install, launch
./build-app.sh release notarize  # notarize, staple, produce dist/Plume-<v>.zip
```

Two developer commands, for tuning against recordings you've kept aside:

```bash
./.build/debug/plume diarize <file.caf>       # print diarizer turns
./.build/debug/plume summarize <session-dir>  # summarize a meeting in place
```


FluidAudio is pinned exactly, and bumping it is a project rather than a chore: it has made
source-breaking changes in patch releases. AGENTS.md is updated in the same commit as the change it
describes.

Issues and pull requests are welcome. Read AGENTS.md §1 first — several behaviours that look like
bugs are invariants protecting something unrecoverable, and several that look like omissions are
decisions with arguments behind them.

## Licence

MIT — see [LICENSE](LICENSE). Quill's copyright notice is retained in
[LICENSE-quill](LICENSE-quill), as its licence requires. Menu bar icon from
[Lucide](https://lucide.dev).
