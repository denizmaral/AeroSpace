@testable import AppBundle
import CoreGraphics
import Testing

/// Two fingers sideways on the trackpad move through the columns of a scrolling workspace (see TrackpadColumnScrolling).
/// A column per 110 points of the fingers
@Suite
struct ColumnScrollGestureTest {
    @Test func testSidewaysMovesColumns() {
        var gesture = ColumnScrollGesture()
        assertEquals(gesture.handle(.began, dx: 0, dy: 0, isWanted: true).verdict, .pass)
        // Too short to tell the direction: the app gets it
        assertEquals(gesture.handle(.changed, dx: -3, dy: 0, isWanted: true).verdict, .pass)
        // Sideways: the app saw the beginning, it gets the end of a canceled gesture
        assertEquals(gesture.handle(.changed, dx: -4, dy: 1, isWanted: true).verdict, .cancelForApp)
        // The fingers go left: the columns on the right come in
        assertEquals(gesture.handle(.changed, dx: -60, dy: 0, isWanted: true).columns, 0)
        assertEquals(gesture.handle(.changed, dx: -60, dy: 0, isWanted: true).columns, 1)
        assertEquals(gesture.handle(.changed, dx: -230, dy: 0, isWanted: true).columns, 2)
        // It moved columns: the rest isn't a flick
        assertEquals(gesture.handle(.ended, dx: 0, dy: 0, isWanted: true).verdict, .take)
        // Its momentum doesn't reach the app either, and doesn't move columns
        assertEquals(gesture.handle(.momentum, dx: -80, dy: 0, isWanted: true).verdict, .take)
        assertEquals(gesture.handle(.momentum, dx: -80, dy: 0, isWanted: true).columns, 0)
    }

    @Test func testTheFingersGoingRightBringTheColumnsOnTheLeft() {
        var gesture = ColumnScrollGesture()
        _ = gesture.handle(.began, dx: 0, dy: 0, isWanted: true)
        assertEquals(gesture.handle(.changed, dx: 120, dy: 2, isWanted: true).columns, -1)
    }

    /// A quick flick is shorter than a column: it moves one anyway
    @Test func testAFlickMovesAColumn() {
        var gesture = ColumnScrollGesture()
        _ = gesture.handle(.began, dx: 0, dy: 0, isWanted: true)
        assertEquals(gesture.handle(.changed, dx: -25, dy: 0, isWanted: true), (.cancelForApp, 0))
        assertEquals(gesture.handle(.changed, dx: -30, dy: 0, isWanted: true), (.take, 0))
        assertEquals(gesture.handle(.ended, dx: 0, dy: 0, isWanted: true), (.take, 1))

        _ = gesture.handle(.began, dx: 0, dy: 0, isWanted: true)
        _ = gesture.handle(.changed, dx: 40, dy: 0, isWanted: true)
        assertEquals(gesture.handle(.ended, dx: 0, dy: 0, isWanted: true), (.take, -1))
    }

    @Test func testUpAndDownStaysWithTheApp() {
        var gesture = ColumnScrollGesture()
        _ = gesture.handle(.began, dx: 0, dy: 0, isWanted: true)
        assertEquals(gesture.handle(.changed, dx: 3, dy: -12, isWanted: true).verdict, .pass)
        // Later sideways in the same gesture: still the app's
        assertEquals(gesture.handle(.changed, dx: 300, dy: 0, isWanted: true).verdict, .pass)
        assertEquals(gesture.handle(.ended, dx: 0, dy: 0, isWanted: true), (.pass, 0))
        assertEquals(gesture.handle(.momentum, dx: 50, dy: 0, isWanted: true).verdict, .pass)
        // A new gesture decides again
        _ = gesture.handle(.began, dx: 0, dy: 0, isWanted: true)
        assertEquals(gesture.handle(.changed, dx: 20, dy: 0, isWanted: true).verdict, .cancelForApp)
    }

    @Test func testNotWanted() {
        // Over a tiling workspace or a floating window, without the key of the settings, or a mouse wheel
        var gesture = ColumnScrollGesture()
        _ = gesture.handle(.began, dx: 0, dy: 0, isWanted: false)
        assertEquals(gesture.handle(.changed, dx: 300, dy: 0, isWanted: true).verdict, .pass)
        assertEquals(gesture.handle(.ended, dx: 0, dy: 0, isWanted: true), (.pass, 0))
        assertEquals(gesture.handle(.none, dx: 300, dy: 0, isWanted: true).verdict, .pass)
    }
}

private func assertEquals(
    _ actual: (verdict: ColumnScrollGesture.Verdict, columns: Int),
    _ expected: (ColumnScrollGesture.Verdict, Int),
    sourceLocation: SourceLocation = #_sourceLocation,
) {
    #expect(actual.verdict == expected.0 && actual.columns == expected.1, "\(actual)", sourceLocation: sourceLocation)
}
