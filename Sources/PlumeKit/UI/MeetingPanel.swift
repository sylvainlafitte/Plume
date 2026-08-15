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

/// The meeting surface: a collapsed pill, a strip during a call, an expanded
/// wrap-up pane after it.
///
/// **Three windows, deliberately** — because the behaviours that distinguish
/// them are fixed in `styleMask` at init and cannot be mutated afterwards
/// without silently breaking typing. Configuration verified in Spike B on macOS
/// 26.5.1 (spikes/panel/RESULTS.md):
///
/// - **Recording** is `[.nonactivatingPanel, .titled, .fullSizeContentView]` at
///   `.floating`. `.nonactivatingPanel` means clicking doesn't activate Plume,
///   so a video call stays frontmost; `.titled` is what lets it become key,
///   which is what lets you type into it. `.borderless` cannot become key
///   without overriding `canBecomeKey`.
/// - **Wrap-up is an ordinary window** at normal level. The reason to float and
///   not activate expires at Stop: the call is over, so other apps should be
///   able to cover it, and clicking it should activate Plume like any window.
///   That last part is not cosmetic — a `.nonactivatingPanel` can be *key while
///   another app is active*, and key equivalents route through the **active**
///   app's main menu, so ⌘C in such a window reaches nothing. Wrap-up is where
///   you copy a summary out, so it cannot be that kind of window.
/// - **The pill** is `.borderless`, because it only ever gets clicked. It stays
///   floating in both phases: it is the handle you get the window back with.
///
/// The pill's split has a measured reason. A titled window carries an invisible
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
    private var wrap: NSWindow?
    private var wrapHosting: NSHostingView<AnyView>?
    private var pill: NSPanel?
    private var pillHosting: NSHostingView<AnyView>?
    /// Windows hold delegates weakly, so we keep them alive here.
    private var resizeDelegates: [PanelResizeDelegate] = []
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
            showExpanded(mode, content)
        }
    }

    // MARK: - Expanded states

    /// The window currently on screen for an expanded mode, if any. Used to hand
    /// a frame from one window to the next so nothing jumps at Stop.
    private var visibleExpanded: NSWindow? {
        [main as NSWindow?, wrap].compactMap { $0 }.first { $0.isVisible }
    }

    private func showExpanded(_ mode: Mode, _ content: some View) {
        let window: NSWindow = mode == .wrapUp ? ensureWrap() : ensureMain()
        // The titlebar is transparent and hidden but still reserves a safe area;
        // we draw all our own chrome, so there is nothing to leave room for.
        let hosted = AnyView(content.ignoresSafeArea())
        if mode == .wrapUp { wrapHosting?.rootView = hosted } else { mainHosting?.rootView = hosted }

        // Recording and wrap-up are different windows, so continuity is explicit:
        // the incoming one adopts the outgoing one's exact frame. Without this,
        // Stop would teleport the panel to the other window's autosaved position
        // — the same drift that made the pill move before the two modes shared
        // one size.
        if let previous = visibleExpanded, previous !== window {
            window.setFrame(previous.frame, display: false)
            previous.orderOut(nil)
        } else if let pill, pill.isVisible {
            // Expanding from the pill: keep the same top-right corner.
            var frame = window.frame
            frame.origin.x = pill.frame.maxX - frame.width
            frame.origin.y = pill.frame.maxY - frame.height
            window.setFrame(frame, display: false)
            pill.orderOut(nil)
        }

        switch mode {
        case .recording:
            // Become key *without* activating the app. A non-activating panel can
            // hold key while another app stays frontmost — that is what utility
            // panels are for — and focus only follows the key window, so without
            // this the notes field cannot take focus on appear.
            window.orderFrontRegardless()
            window.makeKey()
        case .wrapUp:
            // The call is over; a comfortable typing surface now matters more
            // than staying out of the way. An ordinary activation, so the app's
            // main menu becomes the active one and ⌘C works.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        case .pill:
            break
        }
    }

    // MARK: - Collapsed pill

    private func showPill(_ content: some View) {
        let pill = ensurePill()
        pillHosting?.rootView = AnyView(content)

        // Anchor to the expanded window's top-right so collapsing doesn't jump —
        // whichever of the two is up. Falls back to building the recording panel
        // when neither has been shown, because a recording now starts collapsed:
        // its autosaved frame is where the user last left the panel, which is a
        // better guess than a screen corner.
        let anchor = visibleExpanded ?? ensureMain()
        pill.setFrameOrigin(NSPoint(
            x: anchor.frame.maxX - Self.pillSize.width,
            y: anchor.frame.maxY - Self.pillSize.height))
        anchor.orderOut(nil)
        pill.orderFrontRegardless()
    }

    // MARK: - Visibility

    var isVisible: Bool {
        (main?.isVisible ?? false) || (wrap?.isVisible ?? false) || (pill?.isVisible ?? false)
    }

    func hide() {
        // Drop the SwiftUI trees too: a hidden hosting view otherwise keeps
        // participating in layout and observation every frame.
        mainHosting?.rootView = AnyView(EmptyView())
        wrapHosting?.rootView = AnyView(EmptyView())
        pillHosting?.rootView = AnyView(EmptyView())
        main?.orderOut(nil)
        wrap?.orderOut(nil)
        pill?.orderOut(nil)
    }

    func focus() {
        guard let window = visibleExpanded ?? (mode == .wrapUp ? wrap : main) else { return }
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Construction

    /// Settings every one of the three windows wants, regardless of level.
    private func applyShared(to window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        // Deliberately NOT movable by background: that makes any drag on content
        // move the window, which silently breaks drag-to-select in the summary
        // and swallows drags on the pill as clicks. The header and the pill
        // carry an explicit WindowDragGesture instead.
        window.isMovableByWindowBackground = false
        window.hidesOnDeactivate = false
        // Genuinely excludes the window from screen capture on this OS —
        // measured in Spike B. Still best-effort, so the UI promises nothing.
        window.sharingType = .none
        window.minSize = NSSize(width: 1, height: 1)
        window.contentMinSize = NSSize(width: 1, height: 1)
    }

    /// What makes a window float over a live call. **Not** applied to wrap-up:
    /// once the call is over, other apps are entitled to cover it.
    private func applyFloating(to panel: NSPanel) {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.animationBehavior = .utilityWindow
        // Follow the user across Spaces and survive over a full-screen call.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// The chrome shared by both expanded windows: our own controls instead of
    /// the system's, and a real minimum size now that they can be dragged.
    private func applyExpandedChrome(to window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.minSize = Self.minSize
        window.contentMinSize = Self.minSize
        // `minSize` alone is ignored once a hosting view is installed; the
        // delegate is what actually holds the floor during a drag.
        let delegate = PanelResizeDelegate(minSize: Self.minSize)
        window.delegate = delegate
        resizeDelegates.append(delegate)
        // `.titled` brings buttons that PanelControls replaces.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
    }

    private func hostingView(in panel: NSWindow) -> NSHostingView<AnyView> {
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
        applyFloating(to: panel)
        applyExpandedChrome(to: panel)
        // Renamed: the saved frame from the two-fixed-sizes era would restore a
        // 340×300 or 430×580 panel and read as the change not having landed.
        panel.setFrameAutosaveName("PlumeMeetingPanelSized")

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

    /// The wrap-up window: an ordinary `NSWindow`, not a panel.
    ///
    /// No `.nonactivatingPanel`, no `.floating`, no `.canJoinAllSpaces` — all
    /// three exist to survive a live call, and the call is over. Being ordinary
    /// is what lets another app take the front, and what makes clicking back
    /// activate Plume so the main menu (and therefore ⌘C) is ours.
    private func ensureWrap() -> NSWindow {
        if let wrap { return wrap }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false)
        applyShared(to: window)
        applyExpandedChrome(to: window)
        // Its own autosave: it adopts the recording panel's frame at Stop, so
        // this only decides where a wrap-up lands when nothing preceded it.
        window.setFrameAutosaveName("PlumeWrapUpWindow")

        wrapHosting = hostingView(in: window)

        if window.frame.origin == .zero, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: visible.maxX - window.frame.width - 24,
                y: visible.maxY - window.frame.height - 24))
        }
        wrap = window
        return window
    }

    private func ensurePill() -> NSPanel {
        if let pill { return pill }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.pillSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false)
        applyShared(to: panel)
        // The pill stays floating in both phases: it is the handle you get the
        // window back with, and a handle you have to hunt for is not one.
        applyFloating(to: panel)
        // A rectangular window shadow around a capsule reads as a crop.
        panel.hasShadow = false
        pillHosting = hostingView(in: panel)
        pill = panel
        return panel
    }
}
