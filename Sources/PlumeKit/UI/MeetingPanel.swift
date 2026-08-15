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

/// Enforces the panel's minimum size during a user drag.
///
/// `minSize`/`contentMinSize` are set and are still not honoured here — a
/// live-resized `NSHostingView` reports its own constraints back to the window
/// and wins. `windowWillResize` is the one point AppKit asks before committing,
/// so clamping here holds regardless of what recomputed the limits.
private final class PanelResizeDelegate: NSObject, NSWindowDelegate {
    let minSize: NSSize

    init(minSize: NSSize) {
        self.minSize = minSize
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(
            width: max(frameSize.width, minSize.width),
            height: max(frameSize.height, minSize.height))
    }
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
    /// Windows hold delegates weakly.
    private var resizeDelegate: PanelResizeDelegate?
    private(set) var mode: Mode = .recording

    private static let pillSize = NSSize(width: 62, height: 22)
    /// One size for both expanded modes, and only a starting point — the panel
    /// is resizable and its frame is autosaved, so this is what you get before
    /// you drag a corner, not what you are held to.
    ///
    /// Recording and wrap-up used to be two fixed sizes (340×300 and 430×580)
    /// on the assumption that a live call wanted the smaller footprint. Starting
    /// collapsed made that moot: the panel is only on screen while you are
    /// deliberately writing in it, and the same notes field is the point in both
    /// modes. Two sizes then bought nothing and cost a resize on every stop.
    private static let defaultSize = NSSize(width: 400, height: 480)
    /// Below this the tabs, summarize bar and speaker list stop coexisting.
    private static let minSize = NSSize(width: 300, height: 260)

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

        // No per-mode resize: both expanded modes share one frame, so switching
        // from recording to wrap-up only swaps the content. Whatever size you
        // dragged the panel to is the size it stays.

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

        // Anchor to the expanded panel's top-right so collapsing doesn't jump —
        // and build that panel even when it has never been shown, because a
        // recording now starts collapsed. Its autosaved frame is where the user
        // last left the panel, which is a better guess than a screen corner.
        let main = ensureMain()
        pill.setFrameOrigin(NSPoint(
            x: main.frame.maxX - Self.pillSize.width,
            y: main.frame.maxY - Self.pillSize.height))
        if main.isVisible { main.orderOut(nil) }
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
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            // `.resizable` gives the drag handles on all edges. Set at init and
            // never mutated — changing styleMask afterwards silently breaks
            // typing in a non-activating panel.
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false)
        applyShared(to: panel)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.hasShadow = true
        // A real floor now that the user can drag: applyShared's 1×1 exists for
        // the 22pt pill and would let this one be dragged into nothing. Both
        // properties are set *and* enforced in the delegate, because on their
        // own they are silently ignored once the hosting view is installed.
        panel.minSize = Self.minSize
        panel.contentMinSize = Self.minSize
        let delegate = PanelResizeDelegate(minSize: Self.minSize)
        panel.delegate = delegate
        resizeDelegate = delegate
        // Renamed: the saved frame from the two-fixed-sizes era would restore a
        // 340×300 or 430×580 panel and read as the change not having landed.
        panel.setFrameAutosaveName("PlumeMeetingPanelSized")
        // `.titled` brings buttons that PanelControls replaces.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        mainHosting = hostingView(in: panel)

        if panel.frame.origin == .zero, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - panel.frame.width - 24,
                y: visible.maxY - panel.frame.height - 24))
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
