@testable import AppBundle
import Common
import Foundation
import Testing

/// The test windows belong to one app (pid 0): another app is pid 1
@MainActor
@Suite(.serializedGlobally)
struct FocusAfterCloseTest {
    init() { setUpWorkspacesForTests() }

    private let testAppPid: pid_t = 0
    private let otherAppPid: pid_t = 1

    /// a: the last window, the window that closes. b: the window of the app that got the focus right before
    private func setUpTheSwitchToB() async -> (last: TestWindow, closing: TestWindow, focused: TestWindow) {
        let last = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        let closing = TestWindow.new(id: 2, parent: Workspace.get(byName: "a").rootTilingContainer)
        let focused = TestWindow.new(id: 3, parent: Workspace.get(byName: "b").rootTilingContainer)
        assertEquals(last.focusWindow(), true)
        assertEquals(closing.focusWindow(), true)
        await checkOnFocusChangedCallbacks_nonCancellable() // What a session does: the focused workspace is known
        assertEquals(focused.focusWindow(), true) // The focus moved to b just now
        await checkOnFocusChangedCallbacks_nonCancellable()
        return (last, closing, focused)
    }

    /// The user or an app activated another app, and a window of the workspace that was left closed (a screen sharing app
    /// activated the browser and closed its window): the focus stays. MarSpace went back and activated Finder there
    @Test func testTheFocusStaysWhenAnotherAppWasActivatedAndTheAppOfTheClosedWindowRunsOn() async {
        let (_, closing, focused) = await setUpTheSwitchToB()
        let parent = closing.unbindAsClosed().parent
        moveFocusAfterClose(closedWindowParent: parent, closedWindowPid: otherAppPid, isClosedWindowAppRunning: true, frontmost: activated(testAppPid, after: otherAppPid))
        assertEquals(globalFocus.windowOrNil, focused)
        assertEquals(TestApp.shared.focusedWindow, nil) // Nothing activated
    }

    /// The app quit with its window, macOS activated the next app (on another workspace): back to the workspace of the
    /// closed window. AeroSpace issue #1089
    @Test func testTheFocusGoesBackWhenTheAppOfTheClosedWindowQuit() async {
        let (last, closing, _) = await setUpTheSwitchToB()
        let parent = closing.unbindAsClosed().parent
        moveFocusAfterClose(closedWindowParent: parent, closedWindowPid: otherAppPid, isClosedWindowAppRunning: false, frontmost: activated(testAppPid, after: otherAppPid))
        assertEquals(globalFocus.windowOrNil, last)
        assertEquals(TestApp.shared.focusedWindow, last)
    }

    /// macOS focused the next window of the app, on another workspace: back to the workspace of the closed window
    @Test func testTheFocusGoesBackWhenMacosFocusedTheNextWindowOfTheApp() async {
        let (last, closing, _) = await setUpTheSwitchToB()
        let parent = closing.unbindAsClosed().parent
        moveFocusAfterClose(closedWindowParent: parent, closedWindowPid: testAppPid, isClosedWindowAppRunning: true, frontmost: FrontmostHistory(pid: testAppPid))
        assertEquals(globalFocus.windowOrNil, last)
    }

    @Test func testAWindowOfAWorkspaceLeftLongerAgoChangesNothing() async {
        let (_, closing, focused) = await setUpTheSwitchToB()
        prevFocusedWorkspaceDate = .now - 2
        let parent = closing.unbindAsClosed().parent
        moveFocusAfterClose(closedWindowParent: parent, closedWindowPid: otherAppPid, isClosedWindowAppRunning: false, frontmost: activated(testAppPid, after: otherAppPid))
        assertEquals(globalFocus.windowOrNil, focused)
    }

    /// The app is left active without a window: macOS gets the next window of the workspace. AeroSpace issue #65
    @Test func testAnAppLeftWithoutAWindowGivesTheFocusToTheNextWindowOfTheWorkspace() {
        let next = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        let closing = TestWindow.new(id: 2, parent: Workspace.get(byName: "a").rootTilingContainer)
        assertEquals(next.focusWindow(), true)
        assertEquals(closing.focusWindow(), true)
        let parent = closing.unbindAsClosed().parent
        moveFocusAfterClose(closedWindowParent: parent, closedWindowPid: otherAppPid, isClosedWindowAppRunning: true, frontmost: FrontmostHistory(pid: otherAppPid))
        assertEquals(globalFocus.windowOrNil, next)
        assertEquals(TestApp.shared.focusedWindow, next)
    }

    /// A window of the focused workspace closed while another app is frontmost (the user switched to it, the session
    /// hasn't seen it yet): MarSpace doesn't activate the next window of the workspace, it would take the focus from that app
    @Test func testAWindowThatClosesWhileAnotherAppIsFrontmostActivatesNothing() {
        let next = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        let closing = TestWindow.new(id: 2, parent: Workspace.get(byName: "a").rootTilingContainer)
        assertEquals(next.focusWindow(), true)
        assertEquals(closing.focusWindow(), true)
        let parent = closing.unbindAsClosed().parent
        moveFocusAfterClose(closedWindowParent: parent, closedWindowPid: otherAppPid, isClosedWindowAppRunning: true, frontmost: activated(2, after: otherAppPid))
        assertEquals(TestApp.shared.focusedWindow, nil)
    }

    /// An app that didn't have the focus quit (it was activated a while ago, then the user went to another app): the focus
    /// stays with the app that has it. MarSpace activated Finder on the workspace of the window of the app that quit
    @Test func testAnAppThatQuitInTheBackgroundActivatesNothing() {
        let next = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        let closing = TestWindow.new(id: 2, parent: Workspace.get(byName: "a").rootTilingContainer)
        assertEquals(next.focusWindow(), true)
        assertEquals(closing.focusWindow(), true)
        let parent = closing.unbindAsClosed().parent
        moveFocusAfterClose(closedWindowParent: parent, closedWindowPid: otherAppPid, isClosedWindowAppRunning: false, frontmost: activated(5, after: otherAppPid, secondsAgo: 7))
        assertEquals(TestApp.shared.focusedWindow, nil)
    }

    /// The frontmost app quit and macOS gave the focus to the next app: macOS gets the next window of the workspace
    @Test func testTheFrontmostAppThatQuitGivesTheFocusToTheNextWindowOfTheWorkspace() {
        let next = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        let closing = TestWindow.new(id: 2, parent: Workspace.get(byName: "a").rootTilingContainer)
        assertEquals(next.focusWindow(), true)
        assertEquals(closing.focusWindow(), true)
        let parent = closing.unbindAsClosed().parent
        moveFocusAfterClose(closedWindowParent: parent, closedWindowPid: otherAppPid, isClosedWindowAppRunning: false, frontmost: activated(5, after: otherAppPid))
        assertEquals(TestApp.shared.focusedWindow, next)
    }

    @Test func testTheHistoryRecordsWhichAppHadTheFocusBefore() {
        let start = ContinuousClock.now
        let history = FrontmostHistory(pid: 1).changed(to: 2, at: start)
        assertEquals(history, FrontmostHistory(pid: 2, previousPid: 1, changedAt: start))
        assertEquals(history.changed(to: 2, at: start + .seconds(5)), history) // No change
        assertEquals(history.passedTheFocusOn(1, within: .seconds(1), now: start + .milliseconds(500)), true)
        assertEquals(history.passedTheFocusOn(1, within: .seconds(1), now: start + .seconds(2)), false)
        assertEquals(history.passedTheFocusOn(2, within: .seconds(1), now: start), false)
    }

    /// `pid` got the focus from `previous`
    private func activated(_ pid: pid_t, after previous: pid_t, secondsAgo: Int64 = 0) -> FrontmostHistory {
        FrontmostHistory(pid: previous).changed(to: pid, at: .now - .seconds(secondsAgo))
    }

    @Test func testAProcessThatExistsIsAlive() {
        assertEquals(isProcessAlive(getpid()), true)
        assertEquals(isProcessAlive(pid_t(Int32.max)), false)
    }
}
