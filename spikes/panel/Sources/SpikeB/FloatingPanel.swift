import AppKit
import SwiftUI

/// The panel configuration from docs/PLAN.md F4, verbatim, so the spike tests the real thing.
///
/// `.nonactivatingPanel` is the load-bearing flag: clicking must not activate Plume, so the
/// video call stays frontmost. `.titled` (not `.borderless`) is what allows the panel to become
/// key, which is what lets us type into it — a borderless panel cannot become key without an
/// explicit `canBecomeKey` override.
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect, hideFromScreenShare: Bool, content: some View) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        animationBehavior = .utilityWindow

        // Follow the user across Spaces and survive over a full-screen video call.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // The claim under test (B2): this is believed dead against ScreenCaptureKit
        // on macOS 15.4+, having only ever blocked the legacy CoreGraphics path.
        sharingType = hideFromScreenShare ? .none : .readOnly

        let host = NSHostingView(rootView: AnyView(content))
        host.frame = contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        contentView = host
    }
}
