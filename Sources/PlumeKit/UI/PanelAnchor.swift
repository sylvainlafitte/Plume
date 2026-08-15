import Foundation

/// Which corner the collapsed pill and the expanded panel are held together by,
/// and the placement maths that follows from it.
///
/// **Why an anchor at all.** The pill and the expanded window are different
/// sizes, so collapse and expand have to agree on one corner to pivot around —
/// otherwise every round-trip moves the pill by the difference. Which corner is
/// arbitrary; that it is *the same one in both directions* is not.
///
/// This used to be fixed at top-right, which meant a pill parked in a bottom or
/// left corner expanded straight off the screen. The corner is now chosen when
/// the panel expands and reused when it collapses — see `MeetingPanel.anchor`
/// for why it is stored rather than re-derived.
///
/// Deliberately screen-free: it takes the usable area as a parameter so the
/// geometry is testable without a display. `MeetingPanel.visibleArea` is the only
/// place that asks AppKit which screen we are on.
struct PanelAnchor: Equatable {
    /// Hold the trailing edges together rather than the leading ones.
    var right: Bool
    /// Hold the top edges together rather than the bottom ones.
    var top: Bool

    /// Top-right: where the panel is first placed, so it is what everything
    /// starts as and what a screen with room keeps.
    static let preferred = PanelAnchor(right: true, top: true)

    /// The corner to expand `size` from `pivot` by: `preferred`, unless holding
    /// that corner would put the window past the left or bottom edge of
    /// `visible`, in which case that axis flips.
    ///
    /// Flip-on-need, not flip-on-which-half: where there is room the result is
    /// exactly the old behaviour, so this can only change cases that used to
    /// overflow.
    static func expanding(from pivot: CGRect, to size: CGSize, within visible: CGRect) -> PanelAnchor {
        PanelAnchor(
            right: pivot.maxX - size.width >= visible.minX,
            top: pivot.maxY - size.height >= visible.minY)
    }

    /// Place `size` so this corner of it coincides with the same corner of
    /// `pivot`. Used in both directions — expand pivots on the pill, collapse
    /// pivots on the window — which is what makes the round-trip exact.
    func frame(of size: CGSize, pivotedOn pivot: CGRect) -> CGRect {
        CGRect(
            x: right ? pivot.maxX - size.width : pivot.minX,
            y: top ? pivot.maxY - size.height : pivot.minY,
            width: size.width,
            height: size.height)
    }

    /// Last line of defence. Flipping picks a corner that fits *usually*, and
    /// there are cases where none does — a window taller than the display, or a
    /// pill parked mid-edge with too little room on either side. Shrink to fit,
    /// then shift inside.
    static func constrain(_ frame: CGRect, within visible: CGRect) -> CGRect {
        var result = frame
        result.size.width = min(result.width, visible.width)
        result.size.height = min(result.height, visible.height)
        result.origin.x = min(max(result.minX, visible.minX), visible.maxX - result.width)
        result.origin.y = min(max(result.minY, visible.minY), visible.maxY - result.height)
        return result
    }
}
