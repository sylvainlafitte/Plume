# Spike B — result: **PASS**, and it overturns the `sharingType` claim

**Date:** 2026-08-14 · **Host:** M1 Pro, macOS 26.5.1 (25F80), Xcode 26.4.1, Swift 6.3.1

## Questions

1. Can a `[.nonactivatingPanel, .titled, .fullSizeContentView]` panel accept typed text while
   another app stays frontmost?
2. Is `sharingType = .none` still honoured against modern screen capture?

## Method

One `LSUIElement` app showing two identical panels differing only in `sharingType` —
`.none` (Panel A) vs `.readOnly` (Panel B, control) — each carrying a distinctive marker
string. Content is SwiftUI in an `NSHostingView`, matching what Phase 5 will actually build,
because a SwiftUI `TextField` inside a non-activating panel is the specific combination that
sometimes fails.

## Test 1 — typing while another app is frontmost: **PASS**

- Keystrokes landed in the panel's `TextField`
- `frontmost app` continued to report the *other* application throughout
- App-level focus was never stolen

The F4 configuration works as designed. `.titled` gives the panel key-window status without
`.nonactivatingPanel` surrendering the frontmost app — no `canBecomeKey` override needed.

## Test 2 — screen share: **`.none` STILL WORKS**

QuickTime screen recording of the full desktop, played back:

| Panel | `sharingType` | Marker | In the recording |
|---|---|---|---|
| A | `.none` | `PLUME-SPIKE-B-HIDDEN` | **absent** |
| B | `.readOnly` | `PLUME-SPIKE-B-CONTROL` | present |

**The planning claim was wrong for our target OS.** It said `sharingType = .none` only ever blocked
the legacy CoreGraphics path and is ineffective against ScreenCaptureKit on macOS 15.4+. On
macOS 26.5.1, against QuickTime's ScreenCaptureKit-backed recorder, the excluded window is
genuinely absent from the capture while the control panel appears normally.

### Why the plan got this wrong

The claim was sourced from an Apple DTS forum statement that *"there are no public APIs for
preventing screen capture."* That statement is about Apple declining to **guarantee** exclusion
as a security boundary — which remains true — not about the mechanism being non-functional. The
plan marked it `[verified]`, but what had actually been verified was *that Apple says this*, not
*that it fails on our target OS*. Those are different claims. Worth remembering when reading the
remaining `[verified]` tags: several are citations, not measurements.

### Scope of this result — do not over-claim

- Tested against **QuickTime only**. Zoom, Teams, Meet and browser `getDisplayMedia` all route
  through ScreenCaptureKit too, but were not individually verified. Worth a spot-check against
  whichever conferencing app is actually used.
- Apple still offers no guarantee, so this stays **best-effort, not a security boundary**. It
  hides the panel from capture APIs; it does nothing about a phone camera pointed at the screen.
- Behaviour could regress in any macOS update. This spike is the regression test.

## Consequences for the plan

- **Keep** `sharingType = .none` — it earns its place rather than being a free no-op.
- **Keep** the explicit hide hotkey anyway: defence in depth, and it covers the untested capture
  paths and any future regression.
- **Do not** promise privacy in UI copy. "Hidden from screen sharing" overstates a best-effort
  mechanism; if it's surfaced at all, it should read as a convenience.
- The Phase 5 acceptance criterion "do not test for screen-share invisibility, per B2 it will be
  visible" is **inverted** — it should now assert the panel *is* excluded.

## Reproduce

```bash
cd spikes/panel
./make-app.sh && open SpikeB.app
# type into Panel A while another app is frontmost; record the desktop; compare markers
pkill SpikeB
```
