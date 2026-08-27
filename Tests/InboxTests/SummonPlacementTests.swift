import XCTest
#if SWIFT_PACKAGE
@testable import Inbox
#endif

final class SummonPlacementTests: XCTestCase {
    // Screen A: 1920×1080 with a 25pt menu bar; screen B to its right,
    // 1440×900 with a 25pt menu bar, bottoms aligned at y = 0.
    private let screenA = (
        frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
        visible: NSRect(x: 0, y: 0, width: 1920, height: 1055)
    )
    private let screenB = (
        frame: NSRect(x: 1920, y: 0, width: 1440, height: 900),
        visible: NSRect(x: 1920, y: 0, width: 1440, height: 875)
    )

    private let window = NSRect(x: 600, y: 300, width: 720, height: 480)

    func testStaysWhenWindowAlreadyOnMouseScreen() {
        let frame = SummonPlacement.frame(
            windowFrame: window,
            mouse: NSPoint(x: 100, y: 100),
            screens: [screenA, screenB]
        )
        XCTAssertNil(frame)
    }

    func testMovesCentredIntoMouseScreenVisibleArea() {
        let frame = SummonPlacement.frame(
            windowFrame: window,
            mouse: NSPoint(x: 2000, y: 400),
            screens: [screenA, screenB]
        )
        // Centre of B's visible area is (2640, 437.5); origin rounds to
        // whole points.
        XCTAssertEqual(frame, NSRect(x: 2280, y: 198, width: 720, height: 480))
    }

    func testStaysWhenMouseIsOnNoScreen() {
        let frame = SummonPlacement.frame(
            windowFrame: window,
            mouse: NSPoint(x: 2000, y: 950),
            screens: [screenA, screenB]
        )
        XCTAssertNil(frame)
    }

    func testWindowStraddlingScreensFollowsItsCentre() {
        // Window centre on A (midX 1760); mouse on A → no move even though
        // the window's right edge pokes into B.
        let straddling = NSRect(x: 1400, y: 300, width: 720, height: 480)
        XCTAssertNil(SummonPlacement.frame(
            windowFrame: straddling,
            mouse: NSPoint(x: 500, y: 500),
            screens: [screenA, screenB]
        ))
    }
}
