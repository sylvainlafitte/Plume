import Foundation
import Testing

@testable import PlumeKit

/// The screen is 1000×800 with its origin at 0,0 — no menu bar or Dock inset, so
/// the numbers stay readable. macOS coordinates are bottom-left origin.
private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
private let pillSize = CGSize(width: 62, height: 22)
private let panelSize = CGSize(width: 400, height: 480)

/// The pill frame you get by collapsing a panel at `frame` with `anchor`.
private func pill(collapsing frame: CGRect, by anchor: PanelAnchor) -> CGRect {
    anchor.frame(of: pillSize, pivotedOn: frame)
}

@Suite("Panel anchoring")
struct PanelAnchorTests {

    @Test("a pill with room keeps the preferred top-right corner")
    func keepsPreferred() {
        let pill = CGRect(x: 900, y: 700, width: 62, height: 22)
        let anchor = PanelAnchor.expanding(from: pill, to: panelSize, within: screen)
        #expect(anchor == .preferred)

        let expanded = anchor.frame(of: panelSize, pivotedOn: pill)
        #expect(expanded.maxX == pill.maxX)
        #expect(expanded.maxY == pill.maxY)
    }

    @Test("a pill near the left edge expands to the right instead of off-screen")
    func flipsHorizontally() {
        let pill = CGRect(x: 8, y: 700, width: 62, height: 22)
        let anchor = PanelAnchor.expanding(from: pill, to: panelSize, within: screen)
        #expect(anchor == PanelAnchor(right: false, top: true))

        let expanded = anchor.frame(of: panelSize, pivotedOn: pill)
        #expect(expanded.minX == pill.minX)
        #expect(expanded.minX >= screen.minX)
    }

    @Test("a pill near the bottom edge expands upward instead of off-screen")
    func flipsVertically() {
        let pill = CGRect(x: 900, y: 10, width: 62, height: 22)
        let anchor = PanelAnchor.expanding(from: pill, to: panelSize, within: screen)
        #expect(anchor == PanelAnchor(right: true, top: false))

        let expanded = anchor.frame(of: panelSize, pivotedOn: pill)
        #expect(expanded.minY == pill.minY)
        #expect(expanded.minY >= screen.minY)
    }

    @Test("a pill in the bottom-left corner flips both axes")
    func flipsBothAxes() {
        let pill = CGRect(x: 4, y: 4, width: 62, height: 22)
        let anchor = PanelAnchor.expanding(from: pill, to: panelSize, within: screen)
        #expect(anchor == PanelAnchor(right: false, top: false))

        let expanded = PanelAnchor.constrain(
            anchor.frame(of: panelSize, pivotedOn: pill), within: screen)
        #expect(screen.contains(expanded))
    }

    /// The property the whole design exists for: the pill comes back to where it
    /// was. It holds only because the anchor is *stored* rather than re-derived —
    /// see the two cases below for what re-deriving would cost.
    @Test("collapsing after expanding returns the pill to its exact origin", arguments: [
        CGRect(x: 900, y: 700, width: 62, height: 22),   // top-right, no flip
        CGRect(x: 8, y: 700, width: 62, height: 22),     // left edge
        CGRect(x: 900, y: 10, width: 62, height: 22),    // bottom edge
        CGRect(x: 4, y: 4, width: 62, height: 22),       // both
    ])
    func roundTripIsExact(start: CGRect) {
        let anchor = PanelAnchor.expanding(from: start, to: panelSize, within: screen)
        let expanded = PanelAnchor.constrain(
            anchor.frame(of: panelSize, pivotedOn: start), within: screen)
        #expect(pill(collapsing: expanded, by: anchor) == start)
    }

    /// Re-deriving the corner from the *expanded* window is what makes the pill
    /// wander: at the bottom edge the flip pushes the window up, the re-derived
    /// corner then reads "top", and the pill comes back 458pt higher than it left.
    @Test("re-deriving the anchor at collapse time would move the pill")
    func rederivingDrifts() {
        let start = CGRect(x: 900, y: 10, width: 62, height: 22)
        let stored = PanelAnchor.expanding(from: start, to: panelSize, within: screen)
        let expanded = stored.frame(of: panelSize, pivotedOn: start)

        let rederived = PanelAnchor.expanding(from: expanded, to: pillSize, within: screen)
        #expect(rederived != stored)
        #expect(pill(collapsing: expanded, by: rederived) != start)
    }

    @Test("a panel taller than the screen is shrunk to fit rather than clipped")
    func shrinksOversizedFrames() {
        let tall = CGRect(x: 900, y: -200, width: 400, height: 1200)
        let result = PanelAnchor.constrain(tall, within: screen)
        #expect(result.height == screen.height)
        #expect(screen.contains(result))
    }

    @Test("the usable area's own origin is respected, not just its size")
    func respectsNonZeroOrigin() {
        // A second display to the right, with a menu bar inset at the top.
        let secondary = CGRect(x: 1000, y: 0, width: 1000, height: 760)
        let pill = CGRect(x: 1004, y: 4, width: 62, height: 22)
        let anchor = PanelAnchor.expanding(from: pill, to: panelSize, within: secondary)
        let expanded = PanelAnchor.constrain(
            anchor.frame(of: panelSize, pivotedOn: pill), within: secondary)
        #expect(secondary.contains(expanded))
    }
}
