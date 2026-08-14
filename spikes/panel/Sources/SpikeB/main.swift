import AppKit
import SwiftUI

// Spike B — two questions, one app:
//
//  1. Can a [.nonactivatingPanel, .titled, .fullSizeContentView] panel accept typed text
//     while a video call stays frontmost? Watch the live readout while you type.
//
//  2. Is `sharingType = .none` still honoured? Two panels are shown — one .none, one
//     .readOnly as a control. Screen-record the desktop and see which survive. If BOTH
//     appear, .none is dead against ScreenCaptureKit and PLAN.md's B2 is confirmed.

@MainActor
final class SpikeDelegate: NSObject, NSApplicationDelegate {
    var panels: [FloatingPanel] = []
    let hiddenMonitor = FocusMonitor()
    let controlMonitor = FocusMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = NSSize(width: 330, height: 300)
        let x = visible.maxX - size.width - 24

        let hidden = FloatingPanel(
            contentRect: NSRect(
                x: x, y: visible.maxY - size.height - 24,
                width: size.width, height: size.height),
            hideFromScreenShare: true,
            content: SpikeContentView(
                title: "Panel A", hiddenFromShare: true, monitor: hiddenMonitor)
        )

        let control = FloatingPanel(
            contentRect: NSRect(
                x: x, y: visible.maxY - size.height * 2 - 40,
                width: size.width, height: size.height),
            hideFromScreenShare: false,
            content: SpikeContentView(
                title: "Panel B (control)", hiddenFromShare: false, monitor: controlMonitor)
        )

        panels = [hidden, control]
        for panel in panels { panel.orderFrontRegardless() }

        hiddenMonitor.start { [weak hidden] in hidden }
        controlMonitor.start { [weak control] in control }

        print("""
            ── Plume Spike B · floating panel probe ──

            Two panels are now floating top-right.
              Panel A  sharingType = .none      (should be hidden from capture, if that still works)
              Panel B  sharingType = .readOnly  (control — definitely capturable)

            TEST 1 — typing while another app is frontmost
              Open a video call (or any app), then click into Panel A's text field and type.
              Watch "frontmost app" and "NSApp.isActive" in the readout.
              PASS = keystrokes land AND the other app stays frontmost.

            TEST 2 — screen share
              Start a QuickTime screen recording of the whole desktop, then stop and play back.
              Look for PLUME-SPIKE-B-HIDDEN and PLUME-SPIKE-B-CONTROL.
              Both visible  -> sharingType = .none is dead (expected; confirms PLAN.md B2)
              Only CONTROL  -> .none still works, and PLAN.md B2 should be revised.

            Quit with Cmd-Q, or close this app from the menu bar.
            """)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
// .accessory: no Dock icon, matching the real menubar app — and the condition under which
// non-activating behaviour actually matters.
app.setActivationPolicy(.accessory)
let delegate = SpikeDelegate()
app.delegate = delegate
app.run()
