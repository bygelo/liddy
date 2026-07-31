import XCTest
@testable import LiddyKit

/// The panel is a dropdown: it hangs from the menu bar and grows **downward**. Getting
/// that backwards puts new space above the content and slides everything the user is
/// reading out from under the pointer — which is exactly what switching to "Lid shut"
/// did, because that mode starts an 8h timer and the timer bar appears.
final class PanelGeometryTest: XCTestCase {
    private let topLeft = CGPoint(x: 500, y: 900)
    private let width: CGFloat = 340

    private func frame(_ height: CGFloat) -> CGRect {
        PanelGeometry.frame(topLeft: topLeft, width: width, height: height)
    }

    /// The load-bearing property. AppKit's origin is the *bottom*-left corner, so
    /// holding the top still means moving the origin down by exactly the growth.
    func testTopEdgeNeverMovesWhenHeightChanges() {
        let heights: [CGFloat] = [200, 214, 380, 381, 640, 199]
        let top = frame(heights[0]).maxY
        for height in heights {
            XCTAssertEqual(
                frame(height).maxY, top, accuracy: 0.001,
                "height \(height) moved the top edge — the panel is growing upward")
        }
    }

    /// The corollary: growth is absorbed by the bottom edge, one point for one point.
    func testGrowthGoesEntirelyIntoTheBottomEdge() {
        let before = frame(300)
        let after = frame(340)
        XCTAssertEqual(after.maxY, before.maxY, accuracy: 0.001)
        XCTAssertEqual(before.minY - after.minY, 40, accuracy: 0.001)
    }

    func testShrinkingRaisesOnlyTheBottomEdge() {
        let before = frame(400)
        let after = frame(360)
        XCTAssertEqual(after.maxY, before.maxY, accuracy: 0.001)
        XCTAssertEqual(after.minY - before.minY, 40, accuracy: 0.001)
    }

    func testWidthAndLeftEdgeAreUnaffectedByHeight() {
        for height in stride(from: CGFloat(120), through: 900, by: 37) {
            XCTAssertEqual(frame(height).minX, topLeft.x)
            XCTAssertEqual(frame(height).width, width)
        }
    }

    /// A zero-height measurement must not silently invert the rect.
    func testDegenerateHeightIsStillAnchoredAtTheTop() {
        XCTAssertEqual(frame(0).maxY, topLeft.y, accuracy: 0.001)
        XCTAssertEqual(frame(0).height, 0)
    }
}

final class PanelPlacementTest: XCTestCase {
    private let width: CGFloat = 340
    private let inset: CGFloat = 8

    private func x(anchorMidX: CGFloat, screenMinX: CGFloat = 0, screenMaxX: CGFloat = 1920) -> CGFloat {
        PanelGeometry.clampedX(
            anchorMidX: anchorMidX, width: width,
            screenMinX: screenMinX, screenMaxX: screenMaxX, inset: inset)
    }

    func testCentredUnderTheIconWhenThereIsRoom() {
        XCTAssertEqual(x(anchorMidX: 960), 960 - 170)
    }

    /// A status item near the right edge — the common case, since that is where menu
    /// bar items live — must not hang half the panel off the screen.
    func testPushedBackFromTheRightEdge() {
        XCTAssertEqual(x(anchorMidX: 1900), 1920 - width - inset)
    }

    func testPushedBackFromTheLeftEdge() {
        XCTAssertEqual(x(anchorMidX: 10), inset)
    }

    /// A screen narrower than the panel has no valid placement; pick the left edge
    /// rather than returning something past it.
    func testScreenNarrowerThanThePanelFallsBackToTheLeft() {
        XCTAssertEqual(x(anchorMidX: 100, screenMinX: 0, screenMaxX: 200), inset)
    }

    func testSecondaryScreenOffsetIsRespected() {
        XCTAssertEqual(x(anchorMidX: 2900, screenMinX: 1920, screenMaxX: 3840), 2900 - 170)
    }
}
