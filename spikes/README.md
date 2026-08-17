# Spikes

Three questions that had to be measured before they could be designed around. **Only the results
are kept** — the throwaway projects that produced them were deleted once each finding had
graduated into shipping code, where it is now enforced rather than merely recorded.

Each `RESULTS.md` states what was run, on what, and what came back, so a finding can be checked
against a comment that cites it.

| | Question | Answer, and where it lives now |
|---|---|---|
| **A — `responsible-process/`** | Does a `.app` launched from Finder get its own TCC identity for system-audio capture? | Yes — and a bare binary inherits the *responsible* process's, which from a terminal is the terminal. This is why Plume ships as a bundle, why `swift run` cannot test capture, and why the system-audio check plays a tone and inspects the samples instead of trusting a return code (invariant 5) |
| **B — `panel/`** | Can a `[.nonactivatingPanel, .titled]` window accept typed text while a call stays frontmost, and is it visible in a screen share? | Typing works — `.titled` is load-bearing for becoming key. And `sharingType = .none` *does* still exclude the window on macOS 26.5.1, correcting a cited-but-unmeasured claim that it no longer works. Apple declines to guarantee it, so the UI still promises nothing. Both live in `MeetingPanel.swift` |
| **C — `num-ctx/`** | What does a large `num_ctx` actually cost with gemma4? | 16 KiB/token — only 4 of 42 layers carry a full-context cache — so 32768 costs ~552 MiB and generates at 33.6 tok/s, fully on GPU. Hence `Config.summaryContextTokens()`, and why a one-hour meeting summarizes in a single pass |

**If any of these ever looks wrong** — after a macOS update, an Xcode update, or a change to
bundling, signing or entitlements — the shipped diagnostics tell you faster than a spike would:
Setup & Checks captures real audio and reports the measured level. That is the same probe A
graduated into, run against the real bundle rather than a stand-in.
