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

        // App Store is on top in its whole tile now
        assertEquals(tracker.mouseMoved(over: appStore, focused: appStore, now: at(400)), .stay)
        assertEquals(tracker.mouseMoved(over: gitHub, focused: appStore, now: at(500)), .enter)
        assertEquals(tracker.checked(real: gitHub, isRecheck: false, focused: appStore, now: at(505)), gitHub)
    }

    @Test func testAgreeingCheckRunsOnlyWhenTheMouseEntersAnotherWindow() {
        let (first, second) = twoWindows()
        var tracker = FocusFollowsMouseTracker(hitWindow: first)

        assertEquals(tracker.mouseMoved(over: second, focused: first, now: at(0)), .enter)
        assertEquals(tracker.checked(real: second, isRecheck: false, focused: first, now: at(5)), second)
        assertEquals(tracker.mouseMoved(over: second, focused: second, now: at(1000)), .stay)
    }

    /// The window under the mouse was focused by the keyboard, then another one. Moving inside the same window doesn't
    /// take the focus back
    @Test func testSmallMovesDontStealTheFocusChangedByOtherMeans() {
        let workspace = Workspace.get(byName: name)
        let (gitHub, appStore) = twoWindows()
        let terminal = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        var tracker = FocusFollowsMouseTracker(hitWindow: gitHub)

        assertEquals(tracker.mouseMoved(over: appStore, focused: gitHub, now: at(0)), .enter)
        assertNil(tracker.checked(real: gitHub, isRecheck: false, focused: gitHub, now: at(5)))

        assertEquals(tracker.mouseMoved(over: appStore, focused: terminal, now: at(200)), .recheck)
        assertNil(tracker.checked(real: gitHub, isRecheck: true, focused: terminal, now: at(205)))
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
        assertEquals(tracker.mouseMoved(over: floating, focused: tiling, now: at(200)), .recheck)
        assertNil(tracker.checked(real: tiling, isRecheck: true, focused: tiling, now: at(205)))
        // Into the visible part of the floating window
        assertEquals(tracker.mouseMoved(over: floating, focused: tiling, now: at(400)), .recheck)
        assertEquals(tracker.checked(real: floating, isRecheck: true, focused: tiling, now: at(405)), floating)
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
