@testable import AppBundle
import CoreGraphics
import Testing

/// Two fingers sideways on the trackpad move through the columns of a scrolling workspace (see TrackpadColumnScrolling).
/// A column per 110 points of the fingers
@Suite
struct ColumnScrollGestureTest {
    @Test func testSidewaysMovesColumns() {
        var gesture = ColumnScrollGesture()
        assertEquals(gesture.handle(.began, dx: 0, dy: 0, isWanted: true).isTaken, false)
        // Too short to tell the direction: the app gets it
        assertEquals(gesture.handle(.changed, dx: -3, dy: 0, isWanted: true).isTaken, false)
        assertEquals(gesture.handle(.changed, dx: -4, dy: 1, isWanted: true).isTaken, true)
        // The fingers go left: the columns on the right come in
        assertEquals(gesture.handle(.changed, dx: -60, dy: 0, isWanted: true).columns, 0)
        assertEquals(gesture.handle(.changed, dx: -60, dy: 0, isWanted: true).columns, 1)
        assertEquals(gesture.handle(.changed, dx: -230, dy: 0, isWanted: true).columns, 2)
        assertEquals(gesture.handle(.ended, dx: 0, dy: 0, isWanted: true).isTaken, true)
        // Its momentum doesn't reach the app either, and doesn't move columns
        assertEquals(gesture.handle(.momentum, dx: -80, dy: 0, isWanted: true).isTaken, true)
        assertEquals(gesture.handle(.momentum, dx: -80, dy: 0, isWanted: true).columns, 0)
    }

    @Test func testTheFingersGoingRightBringTheColumnsOnTheLeft() {
        var gesture = ColumnScrollGesture()
        _ = gesture.handle(.began, dx: 0, dy: 0, isWanted: true)
        assertEquals(gesture.handle(.changed, dx: 120, dy: 2, isWanted: true).columns, -1)
    }

    @Test func testUpAndDownStaysWithTheApp() {
        var gesture = ColumnScrollGesture()
        _ = gesture.handle(.began, dx: 0, dy: 0, isWanted: true)
        assertEquals(gesture.handle(.changed, dx: 3, dy: -12, isWanted: true).isTaken, false)
        // Later sideways in the same gesture: still the app's
        assertEquals(gesture.handle(.changed, dx: 300, dy: 0, isWanted: true).isTaken, false)
        assertEquals(gesture.handle(.momentum, dx: 50, dy: 0, isWanted: true).isTaken, false)
        // A new gesture decides again
        _ = gesture.handle(.began, dx: 0, dy: 0, isWanted: true)
        assertEquals(gesture.handle(.changed, dx: 20, dy: 0, isWanted: true).isTaken, true)
    }

    @Test func testNotWanted() {
        // Over a tiling workspace, without the modifier of the settings, or a mouse wheel
        var gesture = ColumnScrollGesture()
        _ = gesture.handle(.began, dx: 0, dy: 0, isWanted: false)
        assertEquals(gesture.handle(.changed, dx: 300, dy: 0, isWanted: true).isTaken, false)
        assertEquals(gesture.handle(.none, dx: 300, dy: 0, isWanted: true).isTaken, false)
    }
}
