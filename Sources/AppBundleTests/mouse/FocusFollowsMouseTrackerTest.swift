@testable import AppBundle
import Common
import Testing

/// Focus follows the mouse into the window that is really on top, also where the rects of the last layout are not what is
/// on the screen. See FocusFollowsMouseTracker
@MainActor
@Suite(.serializedGlobally)
struct FocusFollowsMouseTrackerTest {
    init() { setUpWorkspacesForTests() }

    private let start = ContinuousClock.now

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant { start + .milliseconds(milliseconds) }

    /// GitHub Desktop (left) refuses to shrink to its tile and covers the left part of the App Store tile while focused.
    /// The mouse enters the App Store tile there, then crosses the real border of GitHub Desktop
    @Test func testFocusFollowsAcrossTheRealBorderOfAWiderNeighbor() {
        let (gitHub, appStore) = twoWindows()
        var tracker = FocusFollowsMouseTracker(hitWindow: gitHub)

        assertEquals(tracker.mouseMoved(over: appStore, focused: gitHub, now: at(0)), .enter)
        assertNil(tracker.checked(real: gitHub, isRecheck: false, focused: gitHub, now: at(5)))

        assertEquals(tracker.mouseMoved(over: appStore, focused: gitHub, now: at(50)), .stay)
        assertEquals(tracker.mouseMoved(over: appStore, focused: gitHub, now: at(105)), .recheck)
        assertEquals(tracker.mouseMoved(over: appStore, focused: gitHub, now: at(110)), .stay) // The recheck is running
        assertEquals(tracker.checked(real: gitHub, isRecheck: true, focused: gitHub, now: at(110)), nil)

        assertEquals(tracker.mouseMoved(over: appStore, focused: gitHub, now: at(210)), .recheck)
        assertEquals(tracker.checked(real: appStore, isRecheck: true, focused: gitHub, now: at(215)), appStore)
        tracker.focusChanged(to: appStore, now: at(220))

        // App Store is on top in its whole tile now
        assertEquals(tracker.mouseMoved(over: appStore, focused: appStore, now: at(400)), .stay)
        assertEquals(tracker.mouseMoved(over: gitHub, focused: appStore, now: at(500)), .enter)
        assertEquals(tracker.checked(real: gitHub, isRecheck: false, focused: appStore, now: at(505)), gitHub)
    }

    /// App Store under the mouse is focused, the keyboard focuses GitHub Desktop: it covers the left part of the App Store
    /// tile now. The mouse moves over it, and back into App Store without leaving the App Store tile
    @Test func testKeyboardFocusedNeighborCoversAPartOfTheWindowUnderTheMouse() {
        let (gitHub, appStore) = twoWindows()
        var tracker = FocusFollowsMouseTracker(hitWindow: gitHub)
        assertEquals(tracker.mouseMoved(over: appStore, focused: appStore, now: at(0)), .leave)

        tracker.focusChanged(to: gitHub, now: at(100))
        // Only learns what is under the mouse
        assertEquals(tracker.mouseMoved(over: appStore, focused: gitHub, now: at(110)), .recheck)
        assertNil(tracker.checked(real: appStore, isRecheck: true, focused: gitHub, now: at(115)))

        assertEquals(tracker.mouseMoved(over: appStore, focused: gitHub, now: at(150)), .stay)
        assertEquals(tracker.mouseMoved(over: appStore, focused: gitHub, now: at(215)), .recheck)
        assertNil(tracker.checked(real: gitHub, isRecheck: true, focused: gitHub, now: at(220)))
        assertEquals(tracker.mouseMoved(over: appStore, focused: gitHub, now: at(320)), .recheck)
        assertEquals(tracker.checked(real: appStore, isRecheck: true, focused: gitHub, now: at(325)), appStore)
        tracker.focusChanged(to: appStore, now: at(330))
        assertEquals(tracker.mouseMoved(over: appStore, focused: appStore, now: at(1000)), .stay)
    }

    @Test func testAgreeingCheckRunsOnlyWhenTheMouseEntersAnotherWindow() {
        let (first, second) = twoWindows()
        var tracker = FocusFollowsMouseTracker(hitWindow: first)

        assertEquals(tracker.mouseMoved(over: second, focused: first, now: at(0)), .enter)
        assertEquals(tracker.checked(real: second, isRecheck: false, focused: first, now: at(5)), second)
        tracker.focusChanged(to: second, now: at(10))
        assertEquals(tracker.mouseMoved(over: second, focused: second, now: at(1000)), .stay)
    }

    /// The keyboard focused another window. Moving inside the window under the mouse doesn't take the focus back
    @Test func testSmallMovesDontStealTheFocusChangedByOtherMeans() {
        let workspace = Workspace.get(byName: name)
        let (first, second) = twoWindows()
        let third = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        var tracker = FocusFollowsMouseTracker(hitWindow: first)
        assertEquals(tracker.mouseMoved(over: second, focused: second, now: at(0)), .leave)

        tracker.focusChanged(to: third, now: at(100))
        for time in stride(from: 110, through: 1010, by: 150) {
            assertEquals(tracker.mouseMoved(over: second, focused: third, now: at(time)), .recheck)
            assertNil(tracker.checked(real: second, isRecheck: true, focused: third, now: at(time + 5)))
        }
    }

    /// The mouse is in the App Store tile over GitHub Desktop, the keyboard focuses another window
    @Test func testSmallMovesOverAWiderNeighborDontStealTheFocusChangedByOtherMeans() {
        let workspace = Workspace.get(byName: name)
        let (gitHub, appStore) = twoWindows()
        let terminal = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        var tracker = FocusFollowsMouseTracker(hitWindow: gitHub)

        assertEquals(tracker.mouseMoved(over: appStore, focused: gitHub, now: at(0)), .enter)
        assertNil(tracker.checked(real: gitHub, isRecheck: false, focused: gitHub, now: at(5)))
        tracker.focusChanged(to: terminal, now: at(50))

        assertEquals(tracker.mouseMoved(over: appStore, focused: terminal, now: at(200)), .recheck)
        assertNil(tracker.checked(real: gitHub, isRecheck: true, focused: terminal, now: at(205)))
        assertEquals(tracker.mouseMoved(over: appStore, focused: terminal, now: at(400)), .recheck)
        assertNil(tracker.checked(real: gitHub, isRecheck: true, focused: terminal, now: at(405)))
        // Into App Store
        assertEquals(tracker.mouseMoved(over: appStore, focused: terminal, now: at(600)), .recheck)
        assertEquals(tracker.checked(real: appStore, isRecheck: true, focused: terminal, now: at(605)), appStore)
    }

    /// E.g. cmd-tab to the window under the mouse: it's on top in its whole tile
    @Test func testFocusOfTheWindowUnderTheMouseByOtherMeansEndsRechecks() {
        let (gitHub, appStore) = twoWindows()
        var tracker = FocusFollowsMouseTracker(hitWindow: gitHub)

        assertEquals(tracker.mouseMoved(over: appStore, focused: gitHub, now: at(0)), .enter)
        assertNil(tracker.checked(real: gitHub, isRecheck: false, focused: gitHub, now: at(5)))
        tracker.focusChanged(to: appStore, now: at(50))
        assertEquals(tracker.mouseMoved(over: appStore, focused: appStore, now: at(1000)), .stay)
    }

    /// The check started before the focus change may have seen the old z-order: it only learns what is under the mouse
    @Test func testFocusChangeWhileACheckIsRunning() {
        let workspace = Workspace.get(byName: name)
        let (gitHub, appStore) = twoWindows()
        let terminal = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        var tracker = FocusFollowsMouseTracker(hitWindow: gitHub)

        assertEquals(tracker.mouseMoved(over: appStore, focused: gitHub, now: at(0)), .enter)
        assertNil(tracker.checked(real: gitHub, isRecheck: false, focused: gitHub, now: at(5)))
        assertEquals(tracker.mouseMoved(over: appStore, focused: gitHub, now: at(200)), .recheck)
        tracker.focusChanged(to: terminal, now: at(201))
        assertEquals(tracker.mouseMoved(over: appStore, focused: terminal, now: at(202)), .stay) // Still one check at a time
        assertNil(tracker.checked(real: appStore, isRecheck: true, focused: terminal, now: at(205)))
        assertEquals(tracker.mouseMoved(over: appStore, focused: terminal, now: at(400)), .recheck)
        assertNil(tracker.checked(real: appStore, isRecheck: true, focused: terminal, now: at(405)))
    }

    @Test func testMenuOverTheWindow() {
        let (first, second) = twoWindows()
        var tracker = FocusFollowsMouseTracker(hitWindow: first)

        assertEquals(tracker.mouseMoved(over: second, focused: first, now: at(0)), .enter)
        assertNil(tracker.checked(real: nil, isRecheck: false, focused: first, now: at(5)))
        assertEquals(tracker.mouseMoved(over: second, focused: first, now: at(200)), .recheck)
        assertNil(tracker.checked(real: nil, isRecheck: true, focused: first, now: at(205)))
        // The menu is closed
        assertEquals(tracker.mouseMoved(over: second, focused: first, now: at(400)), .recheck)
        assertEquals(tracker.checked(real: second, isRecheck: true, focused: first, now: at(405)), second)
        tracker.focusChanged(to: second, now: at(410))
        assertEquals(tracker.mouseMoved(over: second, focused: second, now: at(1000)), .stay)
    }

    /// The in-memory hit test tries floating windows first, but one can be behind the tiling window
    @Test func testFloatingWindowBehindATilingOne() {
        let workspace = Workspace.get(byName: name)
        let (tiling, focused) = twoWindows()
        let floating = TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)
        var tracker = FocusFollowsMouseTracker(hitWindow: focused)

        assertEquals(tracker.mouseMoved(over: floating, focused: focused, now: at(0)), .enter)
        assertEquals(tracker.checked(real: tiling, isRecheck: false, focused: focused, now: at(5)), tiling)
        tracker.focusChanged(to: tiling, now: at(10))
        assertEquals(tracker.mouseMoved(over: floating, focused: tiling, now: at(200)), .recheck)
        assertNil(tracker.checked(real: tiling, isRecheck: true, focused: tiling, now: at(205)))
        // Into the visible part of the floating window
        assertEquals(tracker.mouseMoved(over: floating, focused: tiling, now: at(400)), .recheck)
        assertEquals(tracker.checked(real: floating, isRecheck: true, focused: tiling, now: at(405)), floating)
        tracker.focusChanged(to: floating, now: at(410))
        assertEquals(tracker.mouseMoved(over: floating, focused: floating, now: at(1000)), .stay)
    }

    @Test func testEnteringTheFocusedWindowOrAGapNeedsNoCheck() {
        let (first, second) = twoWindows()
        var tracker = FocusFollowsMouseTracker(hitWindow: first)

        assertEquals(tracker.mouseMoved(over: nil, focused: second, now: at(0)), .leave)
        assertEquals(tracker.mouseMoved(over: second, focused: second, now: at(10)), .leave)
        assertEquals(tracker.mouseMoved(over: second, focused: second, now: at(1000)), .stay)
    }

    /// A disagreement is about the window it was found in
    @Test func testEnteringAnotherWindowEndsRechecks() {
        let (first, second) = twoWindows()
        var tracker = FocusFollowsMouseTracker(hitWindow: first)

        assertEquals(tracker.mouseMoved(over: second, focused: first, now: at(0)), .enter)
        assertNil(tracker.checked(real: first, isRecheck: false, focused: first, now: at(5)))
        assertEquals(tracker.mouseMoved(over: first, focused: first, now: at(50)), .leave)
        assertEquals(tracker.mouseMoved(over: first, focused: first, now: at(1000)), .stay)
    }

    private func twoWindows() -> (TestWindow, TestWindow) {
        let workspace = Workspace.get(byName: name)
        return (TestWindow.new(id: 1, parent: workspace.rootTilingContainer), TestWindow.new(id: 2, parent: workspace.rootTilingContainer))
    }
}
