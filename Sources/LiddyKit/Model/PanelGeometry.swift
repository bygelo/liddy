import Foundation
import CoreGraphics

/// Where the menu panel's window goes, as arithmetic.
///
/// Pulled out of the AppKit controller so the one property that matters can actually be
/// asserted: **the top edge never moves when the height changes**. A dropdown hangs
/// from the menu bar, so growing a section has to push the bottom edge down. Getting
/// that backwards puts the new space above the content, sliding everything the user is
/// reading out from under the pointer.
///
/// AppKit's coordinate system is why this is worth stating rather than assuming: a
/// window's origin is its **bottom**-left corner, so holding the top still means moving
/// the origin down by exactly the amount the window grew. Anchoring the origin — the
/// obvious reading of "don't move the window" — grows it upward instead.
public enum PanelGeometry {
    /// The window rect for a panel of `height` hanging from `topLeft`.
    public static func frame(topLeft: CGPoint, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: topLeft.x, y: topLeft.y - height, width: width, height: height)
    }

    /// Horizontal placement: centred under the status item, then pushed back inside the
    /// screen so an item near the right edge does not hang half the panel off it.
    public static func clampedX(
        anchorMidX: CGFloat,
        width: CGFloat,
        screenMinX: CGFloat,
        screenMaxX: CGFloat,
        inset: CGFloat
    ) -> CGFloat {
        let ideal = anchorMidX - width / 2
        let lower = screenMinX + inset
        let upper = screenMaxX - width - inset
        guard upper > lower else { return lower }
        return min(max(ideal, lower), upper)
    }
}
