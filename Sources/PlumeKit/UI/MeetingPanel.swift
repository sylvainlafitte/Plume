import AppKit
import SwiftUI

/// Delivers the *first* click to the control under the cursor.
///
/// A non-activating panel is not key until you click it, so by default the first
/// click only raises the window and the second reaches the text field — which
/// reads as the field being broken. Accepting first mouse makes one click do
/// both, without the panel ever activating the app.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The floating panel: a collapsed pill, a strip during a call, an expanded
/// wrap-up pane after it.
///
/// **Two windows, deliberately.** Configuration verified in Spike B on macOS
/// 26.5.1 (spikes/panel/RESULTS.md):
///
/// - The expanded states use `[.nonactivatingPanel, .titled, .fullSizeContentView]`.
///   `.nonactivatingPanel` means clicking doesn't activate Plume, so a video call
///   stays frontmost; `.titled` is what lets the panel become key, which is what
///   lets you type into it. `.borderless` cannot become key without overriding
///   `canBecomeKey`.
/// - The pill is a separate `.borderless` window, because it only gets clicked.
///
/// The split exists for a measured reason. A titled window carries an invisible
/// ~28pt titlebar, and at 22pt tall its `contentLayoutRect` collapses to **zero
/// height** — logged, after three failed attempts to work around it by other
/// means. SwiftUI derives its safe area from that rect, so the pill's content
/// was laid out below the visible window regardless of `ignoresSafeArea`. A
/// borderless window has no titlebar to fight.

@MainActor
final class MeetingPanel {

    enum Mode: Equatable {
        /// Collapsed to a small floating pill. Click to expand.
        case pill
        /// Live: notes field, never steals focus.
        case recording
        /// Stopped: expanded, focused, waiting for wrap-up notes and a summary.
        case wrapUp
    }

    private var main: NSPanel?
    private var mainHosting: NSHostingView<AnyView>?
    private var pill: NSPanel?
    private var pillHosting: NSHostingView<AnyView>?
    private(set) var mode: Mode = .recording

    private static let pillSize = NSSize(width: 62, height: 22)
    private static let stripSize = NSSize(width: 340, height: 300)
    private static let wrapUpSize = NSSize(width: 430, height: 580)

    func show(_ mode: Mode, content: some View) {
        self.mode = mode
        if mode == .pill {
            showPill(content)
        } else {
            showMain(mode, content)
        }
    }

    // MARK: - Expanded states

    private func showMain(_ mode: Mode, _ content: some View) {
        let panel = ensureMain()
        // The titlebar is transparent and hidden but still reserves a safe area;
        // we draw all our own chrome, so there is nothing to leave room for.
        mainHosting?.rootView = AnyView(content.ignoresSafeArea())

        let target = mode == .recording ? Self.stripSize : Self.wrapUpSize
        if panel.frame.size != target {
            // Not animated: the content is already the new mode's, so an
            // animated resize would spend its whole duration drawing the new
            // content at the old size.
            var frame = panel.frame
            frame.origin.y += frame.size.height - target.height
            frame.size = target
            panel.setFrame(frame, display: true, animate: false)
        }

        // Expanding from the pill: keep the same top-right corner.
        if let pill, pill.isVisible {
            var frame = panel.frame
            frame.origin.x = pill.frame.maxX - frame.width
            frame.origin.y = pill.frame.maxY - frame.height
            panel.setFrame(frame, display: false)
            pill.orderOut(nil)
        }

        panel.orderFrontRegardless()
        switch mode {
        case .recording:
            // Become key *without* activating the app. A non-activating panel can
            // hold key while another app stays frontmost — that is what utility
            // panels are for — and focus only follows the key window, so without
            // this the notes field cannot take focus on appear.
            panel.makeKey()
        case .wrapUp:
            // The call is over; a comfortable typing surface now matters more
            // than staying out of the way.
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        case .pill:
            break
        }
    }

    // MARK: - Collapsed pill

    private func showPill(_ content: some View) {
        let pill = ensurePill()
        pillHosting?.rootView = AnyView(content)

        // Anchor to the expanded panel's top-right so collapsing doesn't jump.
        if let main, main.isVisible {
            pill.setFrameOrigin(NSPoint(
                x: main.frame.maxX - Self.pillSize.width,
                y: main.frame.maxY - Self.pillSize.height))
            main.orderOut(nil)
        }
        pill.orderFrontRegardless()
    }

    // MARK: - Visibility

    var isVisible: Bool { (main?.isVisible ?? false) || (pill?.isVisible ?? false) }

    func hide() {
        // Drop the SwiftUI trees too: a hidden hosting view otherwise keeps
        // participating in layout and observation every frame.
        mainHosting?.rootView = AnyView(EmptyView())
        pillHosting?.rootView = AnyView(EmptyView())
        main?.orderOut(nil)
        pill?.orderOut(nil)
    }

    func focus() {
        guard let main else { return }
        main.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        main.makeKeyAndOrderFront(nil)
    }

    // MARK: - Construction

    private func applyShared(to panel: NSPanel) {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Deliberately NOT movable by background: that makes any drag on content
        // move the window, which silently breaks drag-to-select in the summary
        // and swallows drags on the pill as clicks. The header and the pill
        // carry an explicit WindowDragGesture instead.
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .utilityWindow
        panel.hidesOnDeactivate = false
        // Follow the user across Spaces and survive over a full-screen call.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Genuinely excludes the window from screen capture on this OS —
        // measured in Spike B. Still best-effort, so the UI promises nothing.
        panel.sharingType = .none
        panel.minSize = NSSize(width: 1, height: 1)
        panel.contentMinSize = NSSize(width: 1, height: 1)
    }

    private func hostingView(in panel: NSPanel) -> NSHostingView<AnyView> {
        let hosting = FirstMouseHostingView(rootView: AnyView(EmptyView()))
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        // Never let SwiftUI's intrinsic size drive the window: the first
        // re-layout after a resize — the once-a-second clock sufficed — would
        // otherwise snap it back to the content's preferred size.
        hosting.sizingOptions = []
        panel.contentView = hosting
        return hosting
    }

    private func ensureMain() -> NSPanel {
        if let main { return main }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.stripSize),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        applyShared(to: panel)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.hasShadow = true
        panel.setFrameAutosaveName("PlumeMeetingPanel")
        // `.titled` brings buttons that PanelControls replaces.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        mainHosting = hostingView(in: panel)

        if panel.frame.origin == .zero, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - Self.stripSize.width - 24,
                y: visible.maxY - Self.stripSize.height - 24))
        }
        main = panel
        return panel
    }

    private func ensurePill() -> NSPanel {
        if let pill { return pill }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.pillSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false)
        applyShared(to: panel)
        // A rectangular window shadow around a capsule reads as a crop.
        panel.hasShadow = false
        pillHosting = hostingView(in: panel)
        pill = panel
        return panel
    }
}
