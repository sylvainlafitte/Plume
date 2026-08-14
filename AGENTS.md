# Working on Plume

Local-only macOS meeting recorder → transcript → AI summary. Menubar app, no cloud.
Forked from [digimata/quill](https://github.com/digimata/quill) (MIT).

> **This file is the source of truth for how Plume works right now.** Keep it that way — see
> [Keeping this file current](#keeping-this-file-current) at the bottom. It is not optional
> housekeeping; it is the only thing carrying hard-won constraints across sessions.

**Precedence when documents disagree:**

1. **The code.** If AGENTS.md contradicts the code, the code is right and this file is stale —
   fix it in the same commit that revealed the drift.
2. **AGENTS.md** — the operative rules as things actually stand.
3. **[docs/PLAN.md](docs/PLAN.md)** — *why* we chose this. Written before implementation, so it
   becomes a design record rather than instructions as phases land. Read it for reasoning; don't
   follow it over this file.

[docs/PROGRESS.md](docs/PROGRESS.md) is orthogonal: what has happened, what's next, and what was
tried and rejected. Log there as you work, especially dead ends.

## Build & test

```bash
swift build            # debug
swift test             # unit tests
swift build -c release
```

The app must run as a real `.app` bundle to capture system audio (see "Invariants"). Testing
by `swift run` will appear to work and silently record silence.

## Constraints an agent will otherwise get wrong

**FluidAudio is pinned `.exact("0.15.5")` on purpose. Do not bump it.** This dependency has
made source-breaking changes in *patch* releases — it broke and reverted the LS-EEND
constructors inside one release, flipped `SpeakerManager` between actor and struct across two
patches, and removed `DownloadUtils` in a patch as "breaking". There is no CHANGELOG. A bump is
a project, not a chore: recompile, then re-run diarization against the test corpus and compare
DER before accepting it. All FluidAudio calls go behind our own protocol so this stays a
one-file diff.

**Swift 6 strict concurrency is on.** `OfflineDiarizerManager` is a `public final class` with
`nonisolated(unsafe)` state — it is *not* `Sendable` and needs an owning actor, not a protocol
existential. Don't reach for `@unchecked Sendable` to make a warning go away; that is exactly
the debt we inherited and removed.

**Use `OfflineDiarizerManager`, not `LSEENDDiarizer`.** The streaming diarizer is roughly twice
the error rate on meeting audio and caps speaker count. We batch, so we use the offline VBx
pipeline. If you find code using the streaming one, it's a mistake.

**Parakeet stays on `.v2`** (English-only, marginally better English WER). `.v3` is FluidAudio's
default, so an omitted `version:` argument silently changes the model.

**Ollama: use the native `/api/chat`, not the OpenAI-compatible `/v1`.** `/v1` has no `options`
passthrough, so `num_ctx` is unsettable there and the context silently defaults to 4096 — which
would quietly summarize only the tail of a long meeting. Always send `num_ctx`, `truncate: false`,
`shift: false`. Talk to `127.0.0.1`, never a LAN address.

**Don't evict other apps' Ollama models.** It's a shared daemon. Unload ours; leave theirs.

## Invariants — breaking these loses user data or trust

1. **Never silently rewrite a marked region.** `meeting.md` has `<!-- plume:notes -->`,
   `<!-- plume:summary -->`, `<!-- plume:transcript -->`. Re-read from disk before every write,
   replace only between markers, and **fail loudly if a marker is missing** — never append a
   duplicate section. Writes go through `FileManager.replaceItemAt`, not `Data.write(.atomic)`
   (which swaps the inode and drops xattrs and Finder tags).
2. **A failed generation must never destroy a good one.** Stream a summary into a buffer;
   replace the region only on success.
3. **Derived names are proposals, not facts.** Speaker names inferred from the transcript are
   pre-filled suggestions requiring one click. A wrong name attributes quotes to a real person
   who didn't say them — worse than an honest `S1`.
4. **System-audio health can only be verified empirically.** Return codes, stream formats and
   packet counts all look correct while recording pure silence. The only real check is: play a
   tone, capture, assert the samples aren't all zero.
5. **Audio is deleted immediately after transcription, by decision.** There is no re-run. Tune
   against the held-aside test corpus, never against production recordings.
6. **The user's Notes region is theirs.** The app writes it during capture and wrap-up; nothing
   downstream rewrites it.

## Upstream

`upstream` remote points at digimata/quill. We cherry-pick from its open PRs (#18 data races,
#2 mic restart, #6 liveness watchdog, #25 echo filter, #20 diarization reference). Upstream has
merged almost nothing, so don't expect to pull. **Attribute cherry-picked work** in the commit
message — it's MIT, not public domain.

## Style

Match Quill's existing voice: small files, comments that explain *why* a non-obvious thing is
done (its Core Audio and voice-processing comments are load-bearing — keep them). No new
dependencies without a note in PROGRESS.md saying what it replaced.

## Keeping this file current

*Last reviewed against the code: 2026-08-14 (pre-implementation — nothing to verify yet).*

**Rule: update this file in the same commit as the change, never "later."** A separate
documentation pass does not happen, and a constraint that is silently wrong is worse than one
that is missing — the next agent will trust it.

### Update it when

- **A constraint here stops being true.** A dependency is bumped, an endpoint or model changes,
  a workaround becomes unnecessary. Edit the claim; don't leave both versions.
- **A spike or experiment answers an open question.** Spike A decides packaging; when it lands,
  the `.app` guidance stops being provisional and says what was actually observed.
- **Something costs you more than ~30 minutes to figure out and isn't obvious from the code.**
  That is the exact definition of what belongs here. If you had to read three files or an
  upstream issue to understand it, write it down.
- **You add or break an invariant.** New rules go in the Invariants list with the consequence of
  breaking them, not just the rule.
- **Build, test, or run commands change** — including anything that must be done a specific way
  to work at all (the `.app`-vs-`swift run` trap is the model here).
- **A phase completes** and changes how you work on the code day to day.

### Don't put here

- Design rationale or alternatives considered → **PLAN.md**
- What happened, current status, dead ends → **PROGRESS.md**
- Anything a competent reader gets from reading the code. This file earns its length by holding
  only what is **non-derivable**: platform traps, silent failures, upstream behaviour, and
  decisions that look arbitrary but aren't.

### Keep it short

Length is the failure mode. If it grows past roughly two screens, something has drifted into it
that belongs in PLAN.md or the code comments. Prune rather than append — a file nobody finishes
reading protects nothing.

### Reviewing

When you touch this file, update the *Last reviewed* date above. If you're starting a session
and that date is far behind the latest commits, spend five minutes checking the Constraints and
Invariants sections against reality before trusting them — and fix what has drifted.
