@testable import AppBundle
import Common
import CoreGraphics
import Testing

/// The layout runs at the end of every refresh session. Unchanged frames must not be sent to the windows again,
/// every send is several accessibility round trips to the app. See Window.setAxFrame
@MainActor
@Suite(.serializedGlobally)
struct LayoutFrameCacheTest {
    init() { setUpWorkspacesForTests() }

    @Test func testUnchangedLayoutSendsNothing() async throws {
        let workspace = Workspace.get(byName: name)
        var windows: [TestWindow] = []
        workspace.rootTilingContainer.apply {
            windows.append(TestWindow.new(id: 1, parent: $0))
            windows.append(TestWindow.new(id: 2, parent: $0))
        }

        try await workspace.layoutWorkspace()
        assertEquals(windows.map(\.sentFrames.count), [1, 1])
        assertEquals(windows[0].sentFrames.first?.size, CGSize(width: 960, height: 1079))

        try await workspace.layoutWorkspace()
        try await workspace.layoutWorkspace()
        assertEquals(windows.map(\.sentFrames.count), [1, 1])
    }

    @Test func testInvalidatedWindowIsSentAgain() async throws {
        let workspace = Workspace.get(byName: name)
        var windows: [TestWindow] = []
        workspace.rootTilingContainer.apply {
            windows.append(TestWindow.new(id: 1, parent: $0))
            windows.append(TestWindow.new(id: 2, parent: $0))
        }
        try await workspace.layoutWorkspace()

        // E.g. the user moved the window with the mouse: kAXMovedNotification
        windows[1].invalidateSentFrame()
        try await workspace.layoutWorkspace()
        assertEquals(windows.map(\.sentFrames.count), [1, 2])
    }

    @Test func testOnlyWindowsWithChangedFramesAreSent() async throws {
        let workspace = Workspace.get(byName: name)
        var windows: [TestWindow] = []
        let root = workspace.rootTilingContainer.apply {
            windows.append(TestWindow.new(id: 1, parent: $0))
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1, index: INDEX_BIND_LAST).apply {
                windows.append(TestWindow.new(id: 2, parent: $0))
                windows.append(TestWindow.new(id: 3, parent: $0))
            }
        }
        try await workspace.layoutWorkspace()
        assertEquals(windows.map(\.sentFrames.count), [1, 1, 1])

        // Only the windows in the right column change
        let column = try #require(root.children.last as? TilingContainer)
        windows[1].setWeight(.v, column.getWeight(.v) * 0.75)
        windows[2].setWeight(.v, column.getWeight(.v) * 0.25)
        try await workspace.layoutWorkspace()
        assertEquals(windows.map(\.sentFrames.count), [1, 2, 2])
    }

    /// The observed frame is what the user sees: App Store refuses to shrink to its tile
    @Test func testObservedFrameIsTheFrameThatTheWindowAccepted() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        appStore.minimumSizeForTest = CGSize(width: 1000, height: 0)
        let gitHub = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()

        assertEquals(appStore.lastAppliedLayoutPhysicalRect?.width, 960) // The tile
        assertEquals(appStore.observedFrame?.width, 1000)
        assertEquals(gitHub.observedFrame, gitHub.lastAppliedLayoutPhysicalRect)
    }

    /// Until the frame is read back, the observed frame is what was sent: most windows accept it
    @Test func testObservedFrameIsTheSentFrameUntilItIsReadBack() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        appStore.minimumSizeForTest = CGSize(width: 1000, height: 0)
        appStore.heldReadBacksForTest = []
        try await workspace.layoutWorkspace()
        assertEquals(appStore.observedFrame?.width, 1920)

        // A new window takes the right half, App Store refuses the left half
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        assertEquals(appStore.observedFrame?.width, 960)
        appStore.deliverReadBacksForTest()
        assertEquals(appStore.observedFrame?.width, 1000)
    }

    /// A read back of an older send arrives after a newer send
    @Test func testReadBackOfAnOlderSendIsIgnored() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        window.heldReadBacksForTest = []
        try await workspace.layoutWorkspace() // 1920 wide
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace() // 960 wide
        for (frame, generation) in (window.heldReadBacksForTest ?? []).reversed() { // The older one arrives last
            window.frameWasReadBack(frame, generation: generation)
        }
        assertEquals(window.observedFrame?.width, 960)
    }

    /// The window was moved or resized by somebody else while its frame was read back: the read back may be from before
    @Test func testReadBackBeforeAnOutsideChangeIsIgnored() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        appStore.minimumSizeForTest = CGSize(width: 1000, height: 0)
        appStore.heldReadBacksForTest = []
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        appStore.invalidateSentFrame() // kAXResizedNotification
        appStore.deliverReadBacksForTest()
        assertEquals(appStore.observedFrame?.width, 960) // Not confirmed. The next layout sends it again and reads it back
        try await workspace.layoutWorkspace()
        appStore.deliverReadBacksForTest()
        assertEquals(appStore.observedFrame?.width, 1000)
    }

    /// The layout sends the same frame again after the sent frame was forgotten (e.g. the app was activated): the window
    /// refuses it again, the observed frame doesn't jump to the tile and back
    @Test func testSendingTheSameFrameAgainKeepsTheObservedFrame() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        appStore.minimumSizeForTest = CGSize(width: 1000, height: 0)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        assertEquals(appStore.observedFrame?.width, 1000)

        appStore.invalidateSentFrame()
        appStore.heldReadBacksForTest = []
        try await workspace.layoutWorkspace()
        assertEquals(appStore.sentFrames.count, 2)
        assertEquals(appStore.observedFrame?.width, 1000)
    }

    /// A workspace switch hides the window in a corner of the screen and shows it again: until it's read back, the
    /// observed frame is what the window made of the same frame the previous time (no border at the tile for a moment)
    @Test func testObservedFrameAfterTheWindowWasHiddenInACorner() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        appStore.minimumSizeForTest = CGSize(width: 1000, height: 0)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        let readBack = try #require(appStore.observedFrame)
        assertEquals(readBack.width, 1000)

        appStore.setAxFrame(CGPoint(x: 1919, y: 1079), nil, readBack: false) // MacWindow.hideInCorner
        appStore.heldReadBacksForTest = []
        try await workspace.layoutWorkspace()
        assertEquals(appStore.observedFrame, readBack)
    }

    /// The read back arrives after the session that sent the frame: it updates the focus border of the focused window, also
    /// while another session is running. The expectation set by the layout doesn't (the session updates it at its end)
    @Test func testReadBackOfTheFocusedWindowUpdatesTheFocusBorder() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        appStore.minimumSizeForTest = CGSize(width: 1000, height: 0)
        let gitHub = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        gitHub.minimumSizeForTest = CGSize(width: 1000, height: 0)
        #expect(appStore.focusWindow())
        appStore.heldReadBacksForTest = []
        gitHub.heldReadBacksForTest = []
        let before = FocusBorderController.shared.readBackUpdates

        try await workspace.layoutWorkspace()
        assertEquals(FocusBorderController.shared.readBackUpdates, before)
        gitHub.deliverReadBacksForTest()
        assertEquals(FocusBorderController.shared.readBackUpdates, before) // Not the focused window
        $refreshSessionEvent.withValue(.hotkeyBinding) { appStore.deliverReadBacksForTest() }
        assertEquals(FocusBorderController.shared.readBackUpdates, before + 1)
    }

    /// Floating windows are read by every layout
    @Test func testObservedFrameOfFloatingWindow() async throws {
        let workspace = Workspace.get(byName: name)
        let rect = Rect(topLeftX: 100, topLeftY: 200, width: 700, height: 500)
        let floating = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer, rect: rect)
        #expect(workspace.focusWorkspace()) // Otherwise the layout moves it to the monitor of the workspace
        try await workspace.layoutWorkspace()
        assertEquals(floating.sentFrames.count, 0)
        assertEquals(floating.observedFrame, rect)

        floating.axRectForTest = Rect(topLeftX: 300, topLeftY: 200, width: 700, height: 500) // Moved by the user
        try await workspace.layoutWorkspace()
        assertEquals(floating.observedFrame?.topLeftX, 300)
    }

    /// A workspace that isn't shown doesn't send a position to the windows that refuse it: a refused frame would be
    /// sent again by every layout
    @Test func testWindowsThatCantBeMovedAreNotHiddenInCorner() {
        let workspace = Workspace.get(byName: name)
        let tiling = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let floating = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        let ofHiddenApp = TestWindow.new(id: 3, parent: workspace.macOsNativeHiddenAppsWindowsContainer)
        TestWindow.new(id: 4, parent: workspace.macOsNativeFullscreenWindowsContainer)
        TestWindow.new(id: 5, parent: workspace.rootTilingContainer).lifeStatus = .invisible // On another macOS Space
        TestWindow.new(id: 6, parent: workspace.rootTilingContainer).lifeStatus = .dead

        assertEquals(workspace.windowsToHideInCorner.map(\.windowId), [tiling, floating, ofHiddenApp].map(\.windowId))
    }
}
