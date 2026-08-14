# Spike A — result: **PASS**

**Date:** 2026-08-14 · **Host:** M1 Pro, macOS 26.5.1 (25F80), Xcode 26.4.1, Swift 6.3.1

## Question

Does a `.app` launched via LaunchServices get its own TCC identity for system-audio capture,
or does it record silence the way a shell-launched binary does
([quill#54](https://github.com/digimata/quill/pull/54))?

This gated the Phase 1 packaging decision in [docs/PLAN.md](../../docs/PLAN.md).

## Method

One binary, two launch contexts. Identical tap code, identical 440 Hz tone played through the
default output device during capture. System volume 19/100, unmuted; **tone confirmed audible
by ear**, which rules out "nothing was playing" as an explanation for silence.

## Measurements

| | Bare binary (`./.build/debug/SpikeA`) | `.app` (`open SpikeA.app`) |
|---|---|---|
| Tap created | yes | yes |
| Aggregate device created | yes | yes |
| IOProc started | yes | yes |
| Stream format | 48000 Hz, 2 ch, 32-bit | 48000 Hz, 2 ch, 32-bit |
| IOProc callbacks | 280 | 278 |
| Samples seen | 286,720 | 284,672 |
| **Non-zero samples** | **0 (0.0%)** | **284,672 (100.0%)** |
| **Peak amplitude** | **−inf dBFS** | **−14.0 dBFS** |
| Permission prompt | none ever appeared | appeared, naming "SpikeA" |

## ⚠️ Follow-up, same day: conclusion 2 below was overstated

Re-running **this same binary** from the same shell hours later gave **99.5% non-zero, −14.0
dBFS** — a pass where it had measured 0.0%. Nothing about the binary changed. What changed is
that the responsible process (the terminal) acquired system-audio permission in the interim,
almost certainly as a side effect of the TCC dialogs approved while testing SpikeA.app and
Plume.app.

**The corrected finding:** a bare binary has no TCC identity of its own and inherits the
responsible process's. That yields silence *when the responsible process lacks the grant*, and
normal capture when it holds it. The original run measured the first case and I generalised it
into "shell launches record silence", which is false.

**What this does not change:** the `.app` decision. A bundle is the only launch context with a
deterministic, self-owned grant and its own prompt — which is what a user double-clicking from
Finder needs. Conclusions 1 and 3 stand, and 3 is *strengthened*: if launch context cannot
predict capture health, the empirical check is the only thing that can.

**Method lesson:** the original result was a single measurement with an uncontrolled variable
(the terminal's TCC state), reported as a general law. Same class of error as the `[verified]`
tag this project already caught in PLAN.md B2 — a real observation, over-generalised.

## Conclusions

1. **The `.app` packaging decision is validated.** A bundle launched through LaunchServices is
   its own responsible process, gets a permission prompt naming itself, and captures real audio.
   Phase 1 proceeds as planned.
2. **quill#54 still reproduces exactly on macOS 26.5.1.** A shell-launched binary produces
   full-length digital silence with no error and no prompt.
3. **Every health signal is useless for detecting this.** In the failing run the tap was created,
   the format was correct, the aggregate device existed, the IOProc fired 280 times at the right
   rate, and every `OSStatus` was `noErr`. Only the sample values differ. This is why the
   `doctor` check must be empirical — tone in, assert non-zero — and why `swift run` must never
   be the way anyone tests audio capture.

## Notes for the real build script

- `codesign` rejects the bundle with *"resource fork, Finder information, or similar detritus
  not allowed"* because SwiftPM's build directory carries extended attributes. `xattr -cr` on
  the assembled `.app` before signing fixes it. This will recur in Phase 1.
- Ad-hoc signing changes the cdhash on every rebuild, so macOS may re-prompt after each build.
  `tccutil reset AudioCapture com.plume.spike-a` clears a remembered decision.
- A grant made *during* a run arrives too late for that run's capture — expect to re-run once
  after granting. Worth handling gracefully in the real app's first-run flow.

## Reproduce

```bash
cd spikes/responsible-process
swift run SpikeA          # expect: FAIL, silent capture (negative control)
./make-app.sh && open SpikeA.app   # expect: PASS, real audio
```

Log accumulates at `~/Library/Logs/plume-spike-a.log`.
