# Spikes

Throwaway-looking code that is **committed on purpose**. Two of these are regression tests in
disguise: they check platform behaviour that can change under us silently, with no compile error
and no runtime error to notice.

Re-run them after: a macOS update, an Xcode update, any change to bundling/signing/entitlements,
or any change to how the app is launched.

## A — `responsible-process/` (go/no-go, blocks Phase 1)

Does a `.app` launched from Finder get its own TCC identity for system-audio capture?

Launch the bundle from Finder, play a tone, capture ~2s of system audio, decode, assert the
samples are not all zero.

**Why this exists:** upstream [quill#54](https://github.com/digimata/quill/pull/54) documented
that a shell-launched binary records *full-length digital silence* — `AudioHardwareCreateProcessTap`
returns `noErr`, `kAudioTapPropertyFormat` reports a correct stream, the aggregate device is
created, `AudioDeviceStart` succeeds, and the IO proc fires at exactly the right rate for the
whole session. Every sample is zero. TCC attributes the request to the *responsible* process,
which from a terminal is the terminal. Binding the embedded Info.plist by signature was reported
as **not sufficient** on its own.

An `.app` via LaunchServices should be its own responsible process — but "should be" is not good
enough for a failure this quiet, and it's the one result that can invalidate the packaging
decision and part of the UI strategy.

**If it fails:** packaging reverts to a LaunchAgent and Phases 5–6 need a different
window-owning approach. Stop and re-plan rather than working around it.

**Graduates to:** the `doctor` system-audio check, which ships.

## B — `panel/` (Phase 5 de-risk)

~40 lines of AppKit. Two questions:

1. Does `[.nonactivatingPanel, .titled, .fullSizeContentView]` with a transparent titlebar accept
   typed text while Zoom stays frontmost?
2. Is the panel visible in a screen share?

**Expected answer to (2) is yes, visible.** `sharingType = .none` only ever blocked the legacy
CoreGraphics path; ScreenCaptureKit — which Zoom, Teams, Meet and QuickTime all use — captures
it anyway since macOS 15.4. Verify with a QuickTime screen recording. We set `sharingType = .none`
regardless because it's free, but the design must not promise privacy. Confirming this early
matters: if it's a dealbreaker, the whole notes-panel concept changes.

## C — `num-ctx/` (Phase 4 sizing)

Load `gemma4:latest` at `num_ctx: 4096` and again at `16384`; record `ollama ps` SIZE for each.

The KV-cache cost has a **~10× spread** depending on whether Ollama trims sliding-window
attention layers (~16 KB/token if SWA-aware, ~172 KB/token if not — the latter blows a 16 GB
budget at 8k context). Phase 4 assumes 8192 fits alongside a 9.6 GB model in a ~10.7 GiB Metal
working set. Measure before writing `SummaryEngine`.

Also worth capturing here: the server log line reporting the VRAM-based default context.
