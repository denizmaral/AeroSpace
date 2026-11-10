@testable import AppBundle
import Common
import CoreGraphics
import Testing

/// Focus follows the mouse into the window that is really on top. The windows under the mouse come from the observed
/// frames (what the user sees: App Store and GitHub Desktop are bigger than their tiles and overlap). See
/// FocusFollowsMouseTracker
@MainActor
@Suite(.serializedGlobally)
struct FocusFollowsMouseTrackerTest {
    init() { setUpWorkspacesForTests() }

    private let start = ContinuousClock.now

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant { start + .milliseconds(milliseconds) }

    /// Mail fills the workspace, a small floating window (focused, e.g. its app was clicked in the Dock) is in front of it.
    /// The mouse crosses Mail on its way to the floating window: Mail isn't focused, it would hide the floating window
    @Test func testFocusedFloatingWindowKeepsTheFocusOverTheTilingWindowBehindIt() async throws {
        let workspace = Workspace.get(byName: name)
        let mail = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        let small = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        small.setAxFrame(CGPoint(x: 600, y: 300), CGSize(width: 400, height: 300))
        var tracker = FocusFollowsMouseTracker(windowsUnderMouse: [], top: nil) // The Dock

        assertEquals(tracker.mouseMoved(over: [mail], focused: small, focusChanges: 0, now: at(0), frontmost: { nil }), .enter)
        assertEquals(tracker.checked(real: mail, focused: small, focusChanges: 0, now: at(5)), nil) // Not focused
        assertEquals(tracker.mouseMoved(over: [mail], focused: small, focusChanges: 0, now: at(20), frontmost: { nil }), .stay)
        // Into the floating window (on top, focused), and back over Mail: still not focused, and no recheck loop
        assertEquals(tracker.mouseMoved(over: [mail, small], focused: small, focusChanges: 0, now: at(40), frontmost: { small }), .leave)
        assertEquals(tracker.mouseMoved(over: [mail], focused: small, focusChanges: 0, now: at(60), frontmost: { nil }), .enter)
        assertEquals(tracker.checked(real: mail, focused: small, focusChanges: 0, now: at(65)), nil)
        assertEquals(tracker.mouseMoved(over: [mail], focused: small, focusChanges: 0, now: at(300), frontmost: { nil }), .stay)
    }

    @Test func testWhereTheMouseMayFocus() async throws {
        let workspace = Workspace.get(byName: name)
        let left = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let right = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        let overLeft = TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)
        overLeft.setAxFrame(CGPoint(x: 100, y: 100), CGSize(width: 300, height: 300))
        let other = TestWindow.new(id: 4, parent: workspace.floatingWindowsContainer)
        other.setAxFrame(CGPoint(x: 200, y: 200), CGSize(width: 300, height: 300))

        #expect(!FocusFollowsMouseTracker.mayFocus(left, from: overLeft)) // A focused floating window over the tiling window
        #expect(FocusFollowsMouseTracker.mayFocus(right, from: overLeft)) // It doesn't overlap the tiling window
        #expect(FocusFollowsMouseTracker.mayFocus(overLeft, from: left)) // Tiling to floating
        #expect(FocusFollowsMouseTracker.mayFocus(other, from: overLeft)) // Floating to floating
        #expect(FocusFollowsMouseTracker.mayFocus(right, from: left)) // Tiling to tiling
        #expect(FocusFollowsMouseTracker.mayFocus(left, from: nil)) // Nothing focused
    }

    /// GitHub Desktop (left, focused) covers a strip of App Store. The mouse moves over the strip into App Store
    @Test func testFocusFollowsAcrossTheRealBorderOfAWiderNeighbor() {
        let (gitHub, appStore, _) = windows()
        var tracker = FocusFollowsMouseTracker(windowsUnderMouse: [gitHub], top: gitHub)

        assertEquals(tracker.mouseMoved(over: [gitHub, appStore], focused: gitHub, focusChanges: 0, now: at(0), frontmost: { gitHub }), .leave) // GitHub Desktop on top
        assertEquals(tracker.mouseMoved(over: [gitHub, appStore], focused: gitHub, focusChanges: 0, now: at(10), frontmost: { gitHub }), .stay)
        assertEquals(tracker.mouseMoved(over: [appStore], focused: gitHub, focusChanges: 0, now: at(20), frontmost: { nil }), .enter)
        assertEquals(tracker.checked(real: appStore, focused: gitHub, focusChanges: 0, now: at(25)), appStore)
        assertEquals(tracker.mouseMoved(over: [appStore], focused: appStore, focusChanges: 0, now: at(1000), frontmost: { nil }), .stay)

        // And back: App Store (focused now) covers the strip
        assertEquals(tracker.mouseMoved(over: [gitHub, appStore], focused: appStore, focusChanges: 0, now: at(1010), frontmost: { appStore }), .leave)
        assertEquals(tracker.mouseMoved(over: [gitHub], focused: appStore, focusChanges: 0, now: at(1020), frontmost: { nil }), .enter)
        assertEquals(tracker.checked(real: gitHub, focused: appStore, focusChanges: 0, now: at(1025)), gitHub)
    }

    /// The keyboard focuses GitHub Desktop while the mouse is over App Store: GitHub Desktop covers the strip now. The
    /// mouse moves over the strip and back into App Store
    @Test func testKeyboardFocusedNeighborCoversAPartOfTheWindowUnderTheMouse() {
        let (gitHub, appStore, _) = windows()
        var tracker = FocusFollowsMouseTracker(windowsUnderMouse: [appStore], top: appStore)

        assertEquals(tracker.mouseMoved(over: [appStore], focused: gitHub, focusChanges: 0, now: at(0), frontmost: { nil }), .stay)
        assertEquals(tracker.mouseMoved(over: [gitHub, appStore], focused: gitHub, focusChanges: 0, now: at(10), frontmost: { gitHub }), .leave)
        assertEquals(tracker.mouseMoved(over: [appStore], focused: gitHub, focusChanges: 0, now: at(20), frontmost: { nil }), .enter)
        assertEquals(tracker.checked(real: appStore, focused: gitHub, focusChanges: 0, now: at(25)), appStore)
    }

    /// The keyboard focused another window. Moving inside the window under the mouse doesn't take the focus back
    @Test func testSmallMovesDontStealTheFocusChangedByOtherMeans() {
        let (_, appStore, terminal) = windows()
        var tracker = FocusFollowsMouseTracker(windowsUnderMouse: [appStore], top: appStore)

        for time in stride(from: 0, through: 1000, by: 50) {
            assertEquals(tracker.mouseMoved(over: [appStore], focused: terminal, focusChanges: 0, now: at(time), frontmost: { nil }), .stay)
        }
    }

    /// App Store is on top of the strip where GitHub Desktop is behind it. Passing over the border of GitHub Desktop is not
    /// entering another window
    @Test func testPassingOverTheBorderOfAWindowBehindDoesntStealTheFocus() {
        let (gitHub, appStore, terminal) = windows()
        var tracker = FocusFollowsMouseTracker(windowsUnderMouse: [appStore], top: appStore)

        assertEquals(tracker.mouseMoved(over: [gitHub, appStore], focused: terminal, focusChanges: 0, now: at(0), frontmost: { appStore }), .leave)
        assertEquals(tracker.mouseMoved(over: [appStore], focused: terminal, focusChanges: 0, now: at(10), frontmost: { nil }), .leave) // No accessibility call
        assertEquals(tracker.mouseMoved(over: [gitHub, appStore], focused: terminal, focusChanges: 0, now: at(20), frontmost: { appStore }), .leave)
    }

    /// Where GitHub Desktop is on top, the mouse is over another window than before
    @Test func testEnteringTheStripWhereTheNeighborIsOnTop() {
        let (gitHub, appStore, terminal) = windows()
        var tracker = FocusFollowsMouseTracker(windowsUnderMouse: [appStore], top: appStore)

        assertEquals(tracker.mouseMoved(over: [gitHub, appStore], focused: terminal, focusChanges: 0, now: at(0), frontmost: { gitHub }), .enter)
        assertEquals(tracker.checked(real: gitHub, focused: terminal, focusChanges: 0, now: at(5)), gitHub)
    }

    @Test func testMenuOverTheWindow() {
        let (first, second, _) = windows()
        var tracker = FocusFollowsMouseTracker(windowsUnderMouse: [first], top: first)

        assertEquals(tracker.mouseMoved(over: [second], focused: first, focusChanges: 0, now: at(0), frontmost: { nil }), .enter)
        assertNil(tracker.checked(real: nil, focused: first, focusChanges: 0, now: at(5)))
        assertEquals(tracker.mouseMoved(over: [second], focused: first, focusChanges: 0, now: at(50), frontmost: { nil }), .stay)
        assertEquals(tracker.mouseMoved(over: [second], focused: first, focusChanges: 0, now: at(200), frontmost: { nil }), .recheck)
        assertEquals(tracker.mouseMoved(over: [second], focused: first, focusChanges: 0, now: at(210), frontmost: { nil }), .stay) // The recheck is running
        assertNil(tracker.checked(real: nil, focused: first, focusChanges: 0, now: at(215)))
        // The menu is closed
        assertEquals(tracker.mouseMoved(over: [second], focused: first, focusChanges: 0, now: at(400), frontmost: { nil }), .recheck)
        assertEquals(tracker.checked(real: second, focused: first, focusChanges: 0, now: at(405)), second)
        assertEquals(tracker.mouseMoved(over: [second], focused: second, focusChanges: 0, now: at(1000), frontmost: { nil }), .stay)
    }

    /// A floating window behind the focused tiling window: its visible part is another window
    @Test func testFloatingWindowBehindTheFocusedTilingWindow() {
        let workspace = Workspace.get(byName: name)
        let (tiling, _, _) = windows()
        let floating = TestWindow.new(id: 4, parent: workspace.floatingWindowsContainer)
        var tracker = FocusFollowsMouseTracker(windowsUnderMouse: [tiling], top: tiling)

        assertEquals(tracker.mouseMoved(over: [floating, tiling], focused: tiling, focusChanges: 0, now: at(0), frontmost: { tiling }), .leave)
        assertEquals(tracker.mouseMoved(over: [floating], focused: tiling, focusChanges: 0, now: at(10), frontmost: { nil }), .enter)
        assertEquals(tracker.checked(real: floating, focused: tiling, focusChanges: 0, now: at(15)), floating)
    }

    @Test func testGapAndReenteringTheWindow() {
        let (first, second, _) = windows()
        var tracker = FocusFollowsMouseTracker(windowsUnderMouse: [first], top: first)

        assertEquals(tracker.mouseMoved(over: [], focused: second, focusChanges: 0, now: at(0), frontmost: { nil }), .leave)
        assertEquals(tracker.mouseMoved(over: [second], focused: second, focusChanges: 0, now: at(10), frontmost: { nil }), .leave)
        // The keyboard focused the other window meanwhile. The mouse left the window and enters it again
        assertEquals(tracker.mouseMoved(over: [], focused: first, focusChanges: 0, now: at(20), frontmost: { nil }), .leave)
        assertEquals(tracker.mouseMoved(over: [second], focused: first, focusChanges: 0, now: at(30), frontmost: { nil }), .enter)
        assertEquals(tracker.checked(real: second, focused: first, focusChanges: 0, now: at(35)), second)
    }

    /// E.g. after Mission Control, the window under the mouse is not focused until the mouse enters another window
    @Test func testWindowUnderTheMouseAtTheStartIsNotFocused() {
        let (first, second, _) = windows()
        var tracker = FocusFollowsMouseTracker(windowsUnderMouse: [first], top: first)

        assertEquals(tracker.mouseMoved(over: [first], focused: second, focusChanges: 0, now: at(0), frontmost: { nil }), .stay)
        assertEquals(tracker.mouseMoved(over: [first, second], focused: second, focusChanges: 0, now: at(10), frontmost: { second }), .leave)
    }

    /// The first accessibility call to App Store after a restart was slow: the keyboard focused GitHub Desktop before the
    /// check of the window under the mouse was done. The later action wins
    @Test func testCheckDoesntFocusAfterTheFocusWasChangedByOtherMeans() {
        let (gitHub, appStore, _) = windows()
        var tracker = FocusFollowsMouseTracker()

        assertEquals(tracker.mouseMoved(over: [appStore], focused: gitHub, focusChanges: 7, now: at(0), frontmost: { nil }), .enter)
        // The keyboard: App Store, then GitHub Desktop again
        assertNil(tracker.checked(real: appStore, focused: gitHub, focusChanges: 9, now: at(600)))
        assertEquals(tracker.mouseMoved(over: [appStore], focused: gitHub, focusChanges: 9, now: at(700), frontmost: { nil }), .stay)
        // Over the strip that GitHub Desktop covers, and back into App Store
        assertEquals(tracker.mouseMoved(over: [gitHub, appStore], focused: gitHub, focusChanges: 9, now: at(800), frontmost: { gitHub }), .leave)
        assertEquals(tracker.mouseMoved(over: [appStore], focused: gitHub, focusChanges: 9, now: at(900), frontmost: { nil }), .enter)
        assertEquals(tracker.checked(real: appStore, focused: gitHub, focusChanges: 9, now: at(905)), appStore)
    }

    @Test func testOnlyFocusChangesByOtherMeansAreCounted() async {
        let (first, second, _) = windows()
        _ = first.focusWindow()
        await checkOnFocusChangedCallbacks_nonCancellable()
        let before = focusChangesByOtherMeans

        _ = second.focusWindow()
        await $refreshSessionEvent.withValue(.focusFollowsMouse) { await checkOnFocusChangedCallbacks_nonCancellable() }
        assertEquals(focusChangesByOtherMeans, before)

        _ = first.focusWindow()
        await $refreshSessionEvent.withValue(.hotkeyBinding) { await checkOnFocusChangedCallbacks_nonCancellable() }
        assertEquals(focusChangesByOtherMeans, before + 1)
    }

    /// Mail is launched while the mouse crosses Terminal. The check focuses Terminal, but when its session starts, macOS has
    /// focused the window of Mail, which its window rule moved to workspace M: Mail keeps the focus
    @Test func testAnAppThatTakesTheFocusWinsOverAnEarlierCheck() {
        let terminal = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        let mail = TestWindow.new(id: 2, parent: Workspace.get(byName: "M").rootTilingContainer)
        _ = terminal.focusWindow()
        updateFocusCache(terminal)
        let focusChanges = focusChangesByOtherMeans // The check found Terminal under the mouse

        updateFocusCache(mail) // The session takes over the macOS focus
        focusFollowsMouse(to: terminal, ifTheFocusDidntChangeSince: focusChanges)
        assertEquals(globalFocus.windowOrNil, mail)
        assertEquals(globalFocus.workspace.name, "M")
    }

    /// The focus that focus-follows-mouse gave arrives in macOS later: not a change by other means
    @Test func testItsOwnFocusInMacOsIsntAChangeByOtherMeans() {
        let (first, second, _) = windows()
        _ = first.focusWindow()
        updateFocusCache(first)
        let focusChanges = focusChangesByOtherMeans

        focusFollowsMouse(to: second, ifTheFocusDidntChangeSince: focusChanges)
        updateFocusCache(second)
        assertEquals(globalFocus.windowOrNil, second)
        assertEquals(focusChangesByOtherMeans, focusChanges)
    }

    /// The mouse moves fast: focus-follows-mouse focuses the first window while the second one is checked
    @Test func testOwnFocusChangeDoesntCancelTheNextCheck() {
        let (first, second, third) = windows()
        var tracker = FocusFollowsMouseTracker(windowsUnderMouse: [third], top: third)

        assertEquals(tracker.mouseMoved(over: [first], focused: third, focusChanges: 3, now: at(0), frontmost: { nil }), .enter)
        assertEquals(tracker.checked(real: first, focused: third, focusChanges: 3, now: at(5)), first)
        assertEquals(tracker.mouseMoved(over: [second], focused: third, focusChanges: 3, now: at(10), frontmost: { nil }), .enter)
        assertEquals(tracker.checked(real: second, focused: first, focusChanges: 3, now: at(15)), second)
    }

    /// A window that floats above the focused one without being focused (always on top, a panel): which one is on top is
    /// checked
    @Test func testFloatingWindowAboveTheFocusedWindow() {
        let workspace = Workspace.get(byName: name)
        let (focused, _, _) = windows()
        let panel = TestWindow.new(id: 4, parent: workspace.floatingWindowsContainer)
        var tracker = FocusFollowsMouseTracker(windowsUnderMouse: [focused], top: focused)

        assertEquals(tracker.mouseMoved(over: [panel, focused], focused: focused, focusChanges: 0, now: at(0), frontmost: { panel }), .enter)
        assertEquals(tracker.checked(real: panel, focused: focused, focusChanges: 0, now: at(5)), panel)
        // Clicked into the panel, then out of it
        assertEquals(tracker.mouseMoved(over: [focused], focused: panel, focusChanges: 1, now: at(100), frontmost: { nil }), .enter)
        assertEquals(tracker.checked(real: focused, focused: panel, focusChanges: 1, now: at(105)), focused)
    }

    /// An accordion is one place on the screen, its most recent window: the others only peek out by the accordion padding
    @Test func testAccordionIsItsMostRecentWindow() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.layout = .accordion
        let (first, second, third) = windows()
        second.markAsMostRecentChild()
        try await workspace.layoutWorkspace()

        assertEquals(workspace.windowsUnderMouse(CGPoint(x: 5, y: 500)), [second]) // The padding of the first window
        assertEquals(workspace.windowsUnderMouse(CGPoint(x: 960, y: 500)), [second])
        assertEquals(workspace.windowsUnderMouse(CGPoint(x: 1915, y: 500)), [second]) // The padding of the last window
        _ = (first, third)
    }

    /// Fast switching: App Store was just focused by the mouse and is on top of the strip in the window server, but the focus
    /// of AeroSpace is still (or again) GitHub Desktop for a moment. The window on top comes from the window server, not
    /// from the focus: moving on into GitHub Desktop focuses it
    @Test func testFocusThatLagsBehindTheStackingDoesntHideTheWindowOnTop() {
        let (gitHub, appStore, _) = windows()
        var tracker = FocusFollowsMouseTracker(windowsUnderMouse: [appStore], top: appStore)

        assertEquals(tracker.mouseMoved(over: [gitHub, appStore], focused: gitHub, focusChanges: 0, now: at(0), frontmost: { appStore }), .leave)
        assertEquals(tracker.mouseMoved(over: [gitHub], focused: appStore, focusChanges: 0, now: at(10), frontmost: { nil }), .enter)
        assertEquals(tracker.checked(real: gitHub, focused: appStore, focusChanges: 0, now: at(15)), gitHub)
    }

    /// Leaving App Store (focused, on top) into GitHub Desktop: the first mouse position is in the resize margin that macOS
    /// hit tests around App Store, the check finds App Store. Checked again on the next moves: GitHub Desktop is focused
    @Test func testCheckThatFindsAWindowNextToTheMouseIsRepeated() {
        let (gitHub, appStore, _) = windows()
        var tracker = FocusFollowsMouseTracker(windowsUnderMouse: [appStore], top: appStore)

        assertEquals(tracker.mouseMoved(over: [gitHub], focused: appStore, focusChanges: 0, now: at(0), frontmost: { nil }), .enter)
        assertNil(tracker.checked(real: appStore, focused: appStore, focusChanges: 0, now: at(5)))
        assertEquals(tracker.mouseMoved(over: [gitHub], focused: appStore, focusChanges: 0, now: at(50), frontmost: { nil }), .stay)
        assertEquals(tracker.mouseMoved(over: [gitHub], focused: appStore, focusChanges: 0, now: at(120), frontmost: { nil }), .recheck)
        assertEquals(tracker.checked(real: gitHub, focused: appStore, focusChanges: 0, now: at(125)), gitHub)
        assertEquals(tracker.mouseMoved(over: [gitHub], focused: gitHub, focusChanges: 0, now: at(1000), frontmost: { nil }), .stay)
    }

    /// The keyboard shows another workspace while the mouse rests: other windows are under the mouse without it crossing a
    /// window border. The first move doesn't focus the window under it, only entering another window does
    @Test func testWindowsUnderTheRestingMouseChangedByAWorkspaceSwitch() {
        let (first, second, third) = windows()
        var tracker = FocusFollowsMouseTracker(windowsUnderMouse: [first], top: first)

        tracker.takeTheNextWindowsAsTheyAre()
        assertEquals(tracker.mouseMoved(over: [second], focused: third, focusChanges: 1, now: at(0), frontmost: { nil }), .leave)
        assertEquals(tracker.mouseMoved(over: [second], focused: third, focusChanges: 1, now: at(500), frontmost: { nil }), .stay)
        assertEquals(tracker.mouseMoved(over: [third], focused: third, focusChanges: 1, now: at(600), frontmost: { nil }), .leave)
        assertEquals(tracker.mouseMoved(over: [second], focused: third, focusChanges: 1, now: at(700), frontmost: { nil }), .enter)
        assertEquals(tracker.checked(real: second, focused: third, focusChanges: 1, now: at(705)), second)
    }

    /// The hit test sees what the user sees, not the tiles: App Store (left) is 1000 wide in its 960 wide tile
    @Test func testWindowsUnderTheMouseAreFoundByTheirObservedFrames() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        appStore.minimumSizeForTest = CGSize(width: 1000, height: 0)
        let gitHub = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()

        let y = 500.0
        assertEquals(workspace.windowsUnderMouse(CGPoint(x: 500, y: y)), [appStore])
        assertEquals(workspace.windowsUnderMouse(CGPoint(x: 980, y: y)), [appStore, gitHub]) // The tile of GitHub Desktop
        assertEquals(workspace.windowsUnderMouse(CGPoint(x: 1500, y: y)), [gitHub])
    }

    private func windows() -> (TestWindow, TestWindow, TestWindow) {
        let workspace = Workspace.get(byName: name)
        return (
            TestWindow.new(id: 1, parent: workspace.rootTilingContainer),
            TestWindow.new(id: 2, parent: workspace.rootTilingContainer),
            TestWindow.new(id: 3, parent: workspace.rootTilingContainer),
        )
    }
}
