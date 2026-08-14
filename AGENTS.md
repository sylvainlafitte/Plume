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

**Update it when:** a constraint here stops being true (dependency bumped, endpoint or model
changed, workaround no longer needed — edit the claim, don't leave both versions); a spike
answers an open question; you add or break an invariant; build/run commands change; or
**something cost you more than ~30 minutes and isn't obvious from the code** — that last one is
the definition of what belongs here.

**Don't put here:** design rationale → PLAN.md. Status and dead ends → PROGRESS.md. Anything a
competent reader gets from the code. This file earns its length by holding only **non-derivable**
things: platform traps, silent failures, upstream behaviour, and decisions that look arbitrary
but aren't.

**Length is the failure mode.** Past ~two screens, something has drifted in that belongs in
PLAN.md or a code comment. Prune rather than append; a file nobody finishes reading protects
nothing.

When you edit this file, bump the *Last reviewed* date. If that date is far behind HEAD at the
start of a session, spend five minutes checking Constraints and Invariants against reality
before trusting them.
