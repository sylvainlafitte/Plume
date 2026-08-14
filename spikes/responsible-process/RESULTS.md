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
