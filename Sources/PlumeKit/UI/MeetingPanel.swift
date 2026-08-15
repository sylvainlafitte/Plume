import AppKit
import SwiftUI

/// The floating panel: a compact strip during a call, an expanded wrap-up pane
/// after it.
///
/// Configuration verified in Spike B on macOS 26.5.1 — see
/// spikes/panel/RESULTS.md. Two flags carry the weight:
///
/// - `.nonactivatingPanel` means clicking the panel does **not** activate Plume,
///   so Zoom stays frontmost and the call keeps running normally.
/// - `.titled` (not `.borderless`) is what lets the panel become key, which is
///   what lets you type into it. A borderless panel cannot become key without
///   overriding `canBecomeKey`; with `.titled` no override is needed.
///
/// `sharingType = .none` genuinely excludes the panel from screen capture on
/// this OS — measured, not assumed. It is still best-effort rather than a
/// guarantee, so the UI promises nothing and a hide hotkey exists regardless.
@MainActor
final class MeetingPanel {

    enum Mode: Equatable {
        /// Collapsed to a small floating pill — the resting state when you want
        /// the screen back. Click it to expand.
        case pill
        /// Live: notes field, never steals focus.
        case recording
        /// Stopped: expanded, focused, waiting for wrap-up notes and a summary.
        case wrapUp
    }

    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private(set) var mode: Mode = .recording

    private static let pillSize = NSSize(width: 132, height: 34)
    private static let stripSize = NSSize(width: 340, height: 300)
    private static let wrapUpSize = NSSize(width: 430, height: 580)

    private static func size(for mode: Mode) -> NSSize {
        switch mode {
        case .pill: return pillSize
        case .recording: return stripSize
        case .wrapUp: return wrapUpSize
        }
    }

    func show(_ mode: Mode, content: some View) {
        self.mode = mode
        let panel = ensurePanel()
        hosting?.rootView = AnyView(content)

        let target = Self.size(for: mode)
        if panel.frame.size != target {
            // Resize rather than restyle. Mutating styleMask after init leaves
            // the window server's activation tag stale, after which typing into
            // a text field silently stops working (Spike B, M4).
            var frame = panel.frame
            frame.origin.y += frame.size.height - target.height
            frame.size = target
            panel.setFrame(frame, display: true, animate: true)
        }

        panel.orderFrontRegardless()
        // Never grab focus for the pill: it exists to be out of the way.
        if mode == .wrapUp {
            // The call is over; a comfortable typing surface is now worth more
            // than staying out of the way.
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func hide() {
        // Also drop the SwiftUI tree: a hidden hosting view otherwise keeps
        // participating in layout and observation every frame.
        hosting?.rootView = AnyView(EmptyView())
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggleVisibility() {
        if isVisible { hide() } else { panel?.orderFrontRegardless() }
    }

    /// Bring the panel forward *and* focus it, for the summon hotkey.
    func focus() {
        guard let panel else { return }
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.stripSize),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow
        panel.hidesOnDeactivate = false
        // Follow the user across Spaces and survive over a full-screen call.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.setFrameAutosaveName("PlumeMeetingPanel")

        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        if panel.frame.origin == .zero, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - Self.stripSize.width - 24,
                y: visible.maxY - Self.stripSize.height - 24))
        }

        self.panel = panel
        self.hosting = hosting
        return panel
    }
}
