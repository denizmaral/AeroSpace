@testable import AppBundle
import Common
import CoreGraphics
import Testing

/// A window can refuse the size of its tile: App Store is at least 1000 wide and covers a part of the next tile, System
/// Settings is at most 740 wide and leaves a part of its tile free. If the windows of a container fit into it as they
/// are, they are moved off each other. The tiles, the weights and the sizes that the windows are asked for stay the
/// same. See TilingContainer.layoutTiles. The test monitor is 1920x1080 (the layout height is 1079), no gaps
@MainActor
@Suite(.serializedGlobally)
struct RefusedTileSizeTest {
    init() { setUpWorkspacesForTests() }

    private let anyHeight = CGFloat.greatestFiniteMagnitude

    @discardableResult
    private func appStore(_ id: OpaqueWindowId, _ parent: NonLeafTreeNodeObject) -> TestWindow {
        TestWindow.new(id: id, parent: parent).apply { $0.minimumSizeForTest = CGSize(width: 1000, height: 0) }
    }

    @discardableResult
    private func systemSettings(_ id: OpaqueWindowId, _ parent: NonLeafTreeNodeObject, width: CGFloat = 740) -> TestWindow {
        TestWindow.new(id: id, parent: parent).apply { $0.maximumSizeForTest = CGSize(width: width, height: anyHeight) }
    }

    /// The first layout learns what the windows make of their tiles, the second one moves them
    private func layoutTwice(_ workspace: Workspace) async throws {
        try await workspace.layoutWorkspace()
        try await workspace.layoutWorkspace()
    }

    private func tile(_ window: TestWindow) -> Rect? { window.lastAppliedLayoutPhysicalRect }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> Rect {
        Rect(topLeftX: x, topLeftY: y, width: width, height: height)
    }

    /// The layouts that the read backs asked for (see Window.rememberSizeAnswer)
    private var layoutsAskedForByReadBacks: Int {
        completeRefreshSessionsAskedForInTests.count { if case .frameReadBack = $0 { true } else { false } }
    }

    @Test func testWindowMovesOffTheBiggerWindowBeforeIt() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = appStore(1, workspace.rootTilingContainer)
        let settings = systemSettings(2, workspace.rootTilingContainer)

        try await workspace.layoutWorkspace()
        assertEquals(appStore.observedFrame, rect(0, 0, 1000, 1079))
        assertEquals(settings.observedFrame, rect(960, 0, 740, 1079)) // Under App Store, 220 are free to the right of it
        // Both answers are new. The two requests are coalesced into one refresh session
        assertEquals(layoutsAskedForByReadBacks, 2)

        try await workspace.layoutWorkspace()
        assertEquals(appStore.observedFrame, rect(0, 0, 1000, 1079))
        assertEquals(settings.observedFrame, rect(1000, 0, 740, 1079))

        // The tiles are the halves of the screen, and the windows are asked for the size of their tiles
        assertEquals(tile(appStore), rect(0, 0, 960, 1079))
        assertEquals(tile(settings), rect(960, 0, 960, 1079))
        assertEquals(appStore.sentFrames.map(\.size), [CGSize(width: 960, height: 1079)])
        assertEquals(settings.sentFrames.map(\.size), [CGSize(width: 960, height: 1079), CGSize(width: 960, height: 1079)])
        assertEquals(settings.sentFrames.map(\.topLeft), [CGPoint(x: 960, y: 0), CGPoint(x: 1000, y: 0)])

        // Nothing changes anymore
        try await workspace.layoutWorkspace()
        try await workspace.layoutWorkspace()
        assertEquals([appStore, settings].map(\.sentFrames.count), [1, 2])
        assertEquals(layoutsAskedForByReadBacks, 2)
    }

    /// The bigger window is the last one: it reaches out of the screen, and comes back into the free part of the tile before it
    @Test func testBiggerWindowMovesBackIntoTheFreeSpaceBeforeIt() async throws {
        let workspace = Workspace.get(byName: name)
        let settings = systemSettings(1, workspace.rootTilingContainer)
        let appStore = appStore(2, workspace.rootTilingContainer)

        try await workspace.layoutWorkspace()
        assertEquals(appStore.observedFrame, rect(960, 0, 1000, 1079))

        try await workspace.layoutWorkspace()
        assertEquals(settings.observedFrame, rect(0, 0, 740, 1079))
        assertEquals(appStore.observedFrame, rect(920, 0, 1000, 1079))
        assertEquals(tile(appStore), rect(960, 0, 960, 1079))

        try await workspace.layoutWorkspace()
        assertEquals([settings, appStore].map(\.sentFrames.count), [1, 2])
    }

    /// App Store and GitHub Desktop: both are at least 1000 wide. They overlap wherever they are, so they stay at their tiles
    @Test func testWindowsThatDontFitStayAtTheirTiles() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = appStore(1, workspace.rootTilingContainer)
        let gitHub = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        gitHub.minimumSizeForTest = CGSize(width: 1000, height: 0)

        try await layoutTwice(workspace)
        try await workspace.layoutWorkspace()
        assertEquals(appStore.observedFrame, rect(0, 0, 1000, 1079))
        assertEquals(gitHub.observedFrame, rect(960, 0, 1000, 1079))
        assertEquals([appStore, gitHub].map(\.sentFrames.count), [1, 1])
    }

    /// 1000 + 930 don't fit into 1920: nothing moves, not even by the 10 that are free
    @Test func testNotEnoughFreeSpaceMovesNothing() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = appStore(1, workspace.rootTilingContainer)
        let settings = systemSettings(2, workspace.rootTilingContainer, width: 930)

        try await layoutTwice(workspace)
        assertEquals(settings.observedFrame, rect(960, 0, 930, 1079))
        assertEquals([appStore, settings].map(\.sentFrames.count), [1, 1])
    }

    /// 1000 + 920 are exactly the 1920 of the screen
    @Test func testExactFit() async throws {
        let workspace = Workspace.get(byName: name)
        appStore(1, workspace.rootTilingContainer)
        let settings = systemSettings(2, workspace.rootTilingContainer, width: 920)

        try await layoutTwice(workspace)
        assertEquals(settings.observedFrame, rect(1000, 0, 920, 1079))
    }

    /// The gap between the windows stays: 1000 + 10 + 915 don't fit into 1920, 1000 + 10 + 910 do, exactly
    @Test func testTheGapDecidesWhetherTheWindowsFit() async throws {
        config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .init(left: 0, bottom: 0, top: 0, right: 0))
        let workspace = Workspace.get(byName: name)
        appStore(1, workspace.rootTilingContainer) // Tiles of 955
        let settings = systemSettings(2, workspace.rootTilingContainer, width: 915)
        try await layoutTwice(workspace)
        assertEquals(settings.observedFrame, rect(965, 0, 915, 1079))

        settings.maximumSizeForTest = CGSize(width: 910, height: anyHeight)
        settings.invalidateSentFrame()
        try await layoutTwice(workspace)
        assertEquals(settings.observedFrame, rect(1010, 0, 910, 1079))
    }

    @Test func testGapsStayBetweenTheWindows() async throws {
        config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .init(left: 20, bottom: 20, top: 20, right: 20))
        let workspace = Workspace.get(byName: name)
        let appStore = appStore(1, workspace.rootTilingContainer)
        let settings = systemSettings(2, workspace.rootTilingContainer)

        try await layoutTwice(workspace)
        assertEquals(tile(appStore), rect(20, 20, 935, 1039))
        assertEquals(tile(settings), rect(965, 20, 935, 1039))
        assertEquals(appStore.observedFrame, rect(20, 20, 1000, 1039))
        assertEquals(settings.observedFrame, rect(1030, 20, 740, 1039))
    }

    /// The last window comes back by as much as it reaches out of the container, the gap stays
    @Test func testBiggerLastWindowWithGaps() async throws {
        config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .init(left: 0, bottom: 0, top: 0, right: 0))
        let workspace = Workspace.get(byName: name)
        let settings = systemSettings(1, workspace.rootTilingContainer)
        let appStore = appStore(2, workspace.rootTilingContainer)

        try await layoutTwice(workspace)
        assertEquals(settings.observedFrame, rect(0, 0, 740, 1079))
        assertEquals(appStore.observedFrame, rect(920, 0, 1000, 1079))
    }

    /// Terminal snaps to its character grid: a window that reaches only into the gap after its tile covers nothing.
    /// Nothing moves, nothing is sent again, and no refresh session is asked for. The tiles aren't whole points
    @Test func testWindowsThatReachOnlyIntoTheGapMoveNothing() async throws {
        config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .init(left: 13, bottom: 13, top: 13, right: 13))
        let workspace = Workspace.get(byName: name)
        let windows = (1 ... 5).map { TestWindow.new(id: OpaqueWindowId($0), parent: workspace.rootTilingContainer) }
        windows[0].maximumSizeForTest = CGSize(width: 300, height: anyHeight)
        windows[1].minimumSizeForTest = CGSize(width: 375, height: 0) // Its tile is 368.8, the gap 10
        windows[2].maximumSizeForTest = CGSize(width: 250, height: 1000)
        windows[4].maximumSizeForTest = CGSize(width: 370, height: anyHeight)

        try await layoutTwice(workspace)
        try await workspace.layoutWorkspace()
        assertEquals(windows.map(\.sentFrames.count), [1, 1, 1, 1, 1])
        assertEquals(windows[2].observedFrame?.topLeftX, tile(windows[2])?.topLeftX)
        assertEquals(layoutsAskedForByReadBacks, 0)
    }

    /// A window between them fills its tile: it keeps its size and moves along
    @Test func testWindowInBetweenMovesAlong() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = appStore(1, workspace.rootTilingContainer) // Tiles of 640
        let between = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        let settings = systemSettings(3, workspace.rootTilingContainer, width: 200)

        try await layoutTwice(workspace)
        assertEquals(appStore.observedFrame, rect(0, 0, 1000, 1079))
        assertEquals(between.observedFrame, rect(1000, 0, 640, 1079))
        assertEquals(settings.observedFrame, rect(1640, 0, 200, 1079))
    }

    /// The free space is before the bigger window and after it: the windows after it don't move further than needed
    @Test func testFreeSpaceOnBothSides() async throws {
        let workspace = Workspace.get(byName: name)
        let first = systemSettings(1, workspace.rootTilingContainer, width: 400) // Tiles of 640
        let appStore = appStore(2, workspace.rootTilingContainer)
        let last = systemSettings(3, workspace.rootTilingContainer, width: 400)

        try await layoutTwice(workspace)
        assertEquals(first.observedFrame, rect(0, 0, 400, 1079))
        assertEquals(appStore.observedFrame, rect(520, 0, 1000, 1079)) // Back by as much as the last window can't make room
        assertEquals(last.observedFrame, rect(1520, 0, 400, 1079))
    }

    @Test func testVerticalContainer() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.changeOrientation(.v)
        let tall = TestWindow.new(id: 1, parent: workspace.rootTilingContainer) // Tiles of 539.5
        tall.minimumSizeForTest = CGSize(width: 0, height: 700)
        let short = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        short.maximumSizeForTest = CGSize(width: anyHeight, height: 300)

        try await layoutTwice(workspace)
        assertEquals(tall.observedFrame, rect(0, 0, 1920, 700))
        assertEquals(short.observedFrame, rect(0, 700, 1920, 300))
    }

    /// The column next to App Store moves as a whole if all of its windows leave enough of their tiles free
    @Test func testNestedContainerMovesAsAWhole() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = appStore(1, workspace.rootTilingContainer)
        let column = TilingContainer.newVTiles(parent: workspace.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let settings = systemSettings(2, column)
        let other = systemSettings(3, column, width: 900)

        try await layoutTwice(workspace)
        assertEquals(appStore.observedFrame, rect(0, 0, 1000, 1079))
        assertEquals(settings.observedFrame, rect(1000, 0, 740, 539.5))
        assertEquals(other.observedFrame, rect(1000, 539.5, 900, 539.5))
        assertEquals(column.lastAppliedLayoutPhysicalRect, rect(960, 0, 960, 1079))
    }

    /// A window of the column fills its tile: the column can't make room, nothing moves
    @Test func testNestedContainerWithAWindowThatFillsItsTileStays() async throws {
        let workspace = Workspace.get(byName: name)
        appStore(1, workspace.rootTilingContainer)
        let column = TilingContainer.newVTiles(parent: workspace.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let settings = systemSettings(2, column)
        let terminal = TestWindow.new(id: 3, parent: column)

        try await layoutTwice(workspace)
        assertEquals(settings.observedFrame, rect(960, 0, 740, 539.5))
        assertEquals(terminal.observedFrame, rect(960, 539.5, 960, 539.5))
        assertEquals([settings, terminal].map(\.sentFrames.count), [1, 1])
    }

    /// The bigger window is inside of a column: the window next to the column makes room for it
    @Test func testBiggerWindowInANestedContainer() async throws {
        let workspace = Workspace.get(byName: name)
        let column = TilingContainer.newVTiles(parent: workspace.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let appStore = appStore(1, column)
        let terminal = TestWindow.new(id: 2, parent: column)
        let settings = systemSettings(3, workspace.rootTilingContainer)

        try await layoutTwice(workspace)
        assertEquals(appStore.observedFrame, rect(0, 0, 1000, 539.5))
        assertEquals(terminal.observedFrame, rect(0, 539.5, 960, 539.5))
        assertEquals(settings.observedFrame, rect(1000, 0, 740, 1079))
    }

    /// The windows of an accordion lie on top of each other on purpose, the accordion as a whole makes room
    @Test func testBiggerWindowInAnAccordion() async throws {
        let workspace = Workspace.get(byName: name)
        let accordion = TilingContainer(parent: workspace.rootTilingContainer, adaptiveWeight: 1, .h, .accordion, index: INDEX_BIND_LAST)
        let appStore = appStore(1, accordion)
        TestWindow.new(id: 2, parent: accordion)
        let settings = systemSettings(3, workspace.rootTilingContainer)

        try await layoutTwice(workspace)
        let appStoreFrame = try #require(appStore.observedFrame)
        let settingsFrame = try #require(settings.observedFrame)
        #expect(settingsFrame.minX >= appStoreFrame.maxX)
        #expect(settingsFrame.maxX <= 1920)
    }

    /// Both read backs arrive after the layout, in any order: the windows are laid out again, once they are known
    @Test func testReadBacksAskForALayoutOnlyIfAWindowCanMove() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = appStore(1, workspace.rootTilingContainer)
        let settings = systemSettings(2, workspace.rootTilingContainer)
        appStore.heldReadBacksForTest = []
        settings.heldReadBacksForTest = []

        try await workspace.layoutWorkspace()
        settings.deliverReadBacksForTest()
        assertEquals(layoutsAskedForByReadBacks, 0) // Smaller than its tile, and nothing is in its way
        appStore.deliverReadBacksForTest()
        assertEquals(layoutsAskedForByReadBacks, 1)

        try await workspace.layoutWorkspace()
        assertEquals(settings.observedFrame, rect(1000, 0, 740, 1079)) // Before it's read back: it's known what it makes of the size
        appStore.deliverReadBacksForTest()
        settings.deliverReadBacksForTest()
        try await workspace.layoutWorkspace()
        assertEquals(layoutsAskedForByReadBacks, 1) // The same answers: no more layouts
        assertEquals([appStore, settings].map(\.sentFrames.count), [1, 2])
    }

    /// A window that is only smaller than its tile doesn't cost refresh sessions
    @Test func testWindowsSmallerThanTheirTilesDontAskForALayout() async throws {
        let workspace = Workspace.get(byName: name)
        let window1 = systemSettings(1, workspace.rootTilingContainer, width: 955)
        let window2 = systemSettings(2, workspace.rootTilingContainer, width: 955)

        try await layoutTwice(workspace)
        assertEquals(layoutsAskedForByReadBacks, 0)
        assertEquals([window1, window2].map(\.sentFrames.count), [1, 1])
    }

    /// A window that isn't there (a tab in the background, on another macOS Space) isn't laid out: its old tile doesn't count
    @Test func testWindowThatIsntThereDoesntAskForLayouts() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = appStore(1, workspace.rootTilingContainer)
        let terminal = systemSettings(2, workspace.rootTilingContainer, width: 955)
        try await layoutTwice(workspace)
        let before = layoutsAskedForByReadBacks

        appStore.lifeStatus = .invisible
        try await layoutTwice(workspace)
        assertEquals(terminal.observedFrame, rect(0, 0, 955, 1079))
        assertEquals(layoutsAskedForByReadBacks, before)
    }

    /// An app is expected to make the same of the same size every time. A window that doesn't isn't followed forever:
    /// every layout that moves it would ask for the next one. After a quiet second, it's followed again
    @Test func testWindowThatAnswersDifferentlyEveryTimeIsNotFollowedForever() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = appStore(1, workspace.rootTilingContainer)
        let settings = systemSettings(2, workspace.rootTilingContainer)
        let start = ContinuousClock.now
        appStore.readBackInstantForTest = start
        try await layoutTwice(workspace)
        assertEquals(layoutsAskedForByReadBacks, 2) // App Store's and System Settings' first answers

        // App Store's first answer and two more in the same second
        for step in 1 ... 5 {
            appStore.minimumSizeForTest = CGSize(width: 1000 + CGFloat(step) * 10, height: 0)
            appStore.readBackInstantForTest = start + .milliseconds(100 * step)
            appStore.invalidateSentFrame() // kAXResizedNotification
            try await workspace.layoutWorkspace()
        }
        assertEquals(layoutsAskedForByReadBacks, 4)

        appStore.minimumSizeForTest = CGSize(width: 1000, height: 0)
        appStore.readBackInstantForTest = start + .seconds(2)
        appStore.invalidateSentFrame()
        try await layoutTwice(workspace)
        assertEquals(layoutsAskedForByReadBacks, 5)
        assertEquals(settings.observedFrame, rect(1000, 0, 740, 1079))
    }

    /// The window changed its mind: it fits its tile now (e.g. another page of the app). The window next to it goes back
    @Test func testBiggerWindowFitsItsTileLater() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = appStore(1, workspace.rootTilingContainer)
        let settings = systemSettings(2, workspace.rootTilingContainer)
        try await layoutTwice(workspace)
        assertEquals(settings.observedFrame, rect(1000, 0, 740, 1079))

        appStore.minimumSizeForTest = nil
        appStore.invalidateSentFrame() // kAXResizedNotification
        try await workspace.layoutWorkspace()
        assertEquals(layoutsAskedForByReadBacks, 3)
        try await workspace.layoutWorkspace()
        assertEquals(appStore.observedFrame, rect(0, 0, 960, 1079))
        assertEquals(settings.observedFrame, rect(960, 0, 740, 1079))
    }

    /// A workspace switch hides the windows in a corner of the screen: when they are shown again, they are where they were,
    /// without a moment at their tiles
    @Test func testWindowsAreBackInPlaceAfterTheyWereHiddenInACorner() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = appStore(1, workspace.rootTilingContainer)
        let settings = systemSettings(2, workspace.rootTilingContainer)
        try await layoutTwice(workspace)

        for window in [appStore, settings] { window.setAxFrame(CGPoint(x: 1919, y: 1079), nil, readBack: false) } // MacWindow.hideInCorner
        let sentBefore = settings.sentFrames.count
        try await workspace.layoutWorkspace()
        assertEquals(settings.sentFrames.dropFirst(sentBefore).map(\.topLeft), [CGPoint(x: 1000, y: 0)])
        assertEquals(settings.observedFrame, rect(1000, 0, 740, 1079))
        assertEquals(appStore.observedFrame, rect(0, 0, 1000, 1079))
    }

    /// macOS fullscreen and back: the size of the tile comes back, and what the window makes of it is still known
    @Test func testWindowsAreInPlaceRightAfterMacosFullscreen() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = appStore(1, workspace.rootTilingContainer)
        let settings = systemSettings(2, workspace.rootTilingContainer)
        try await layoutTwice(workspace)

        #expect(appStore.focusWindow())
        appStore.isFullscreen = true
        try await workspace.layoutWorkspace()
        appStore.isFullscreen = false
        try await workspace.layoutWorkspace()
        assertEquals(appStore.observedFrame, rect(0, 0, 1000, 1079))
        assertEquals(settings.observedFrame, rect(1000, 0, 740, 1079))
        assertEquals(layoutsAskedForByReadBacks, 2) // Only for the first answers
    }

    /// A third window: the tiles are smaller, the windows don't fit anymore and go back to their tiles. It's closed: the
    /// windows are back in place right away
    @Test func testWindowsGoBackToTheirTilesWhenTheyDontFitAnymore() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = appStore(1, workspace.rootTilingContainer)
        let settings = systemSettings(2, workspace.rootTilingContainer)
        try await layoutTwice(workspace)
        assertEquals(settings.observedFrame?.topLeftX, 1000)

        let third = TestWindow.new(id: 3, parent: workspace.rootTilingContainer) // Tiles of 640
        try await layoutTwice(workspace)
        assertEquals(appStore.observedFrame, rect(0, 0, 1000, 1079))
        assertEquals(settings.observedFrame, rect(640, 0, 640, 1079))
        assertEquals(third.observedFrame, rect(1280, 0, 640, 1079))

        third.closeAxWindow()
        try await workspace.layoutWorkspace()
        assertEquals(settings.observedFrame, rect(1000, 0, 740, 1079))
    }

    /// A tile isn't a whole number of points, a window is: half a point more or less isn't a refused size
    @Test func testRoundingIsNotARefusedSize() async throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.changeOrientation(.v)
        let roundsUp = TestWindow.new(id: 1, parent: workspace.rootTilingContainer) // Tiles of 539.5
        roundsUp.minimumSizeForTest = CGSize(width: 0, height: 540)
        let roundsDown = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        roundsDown.maximumSizeForTest = CGSize(width: anyHeight, height: 539)

        try await layoutTwice(workspace)
        assertEquals(roundsUp.isBiggerThanTile, false)
        assertEquals(layoutsAskedForByReadBacks, 0)
        assertEquals([roundsUp, roundsDown].map(\.sentFrames.count), [1, 1])
    }

    /// The window that is resized with the mouse is left alone, and its size follows the mouse: nothing moves for it
    @Test func testWindowManipulatedWithMouseMovesNothing() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = appStore(1, workspace.rootTilingContainer)
        let settings = systemSettings(2, workspace.rootTilingContainer)
        try await layoutTwice(workspace)

        currentlyManipulatedWithMouseWindowId = appStore.windowId
        try await workspace.layoutWorkspace()
        assertEquals(appStore.sentFrames.count, 1)
        assertEquals(settings.sentFrames.last?.topLeft, CGPoint(x: 960, y: 0))
    }

    /// System Settings was moved off App Store (its tile starts at 960, the window at 1000). Its left edge is dragged to
    /// 1100: the edge of its tile goes there, not 40 further
    @Test func testDraggedEdgeOfAMovedWindowGoesToTheMouse() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = appStore(1, workspace.rootTilingContainer)
        let settings = systemSettings(2, workspace.rootTilingContainer)
        try await layoutTwice(workspace)

        settings.axRectForTest = rect(1100, 0, 640, 1079)
        try await resizeWithMouse(settings)
        try await resetManipulatedWithMouseIfPossible()
        try await layoutTwice(workspace)
        assertEquals(tile(appStore)?.width.rounded(), 1100)
        assertEquals(settings.observedFrame?.topLeftX.rounded(), 1100)
    }

    /// Edges that aren't dragged change nothing, also where the window isn't at the edge of its tile (System Settings is
    /// moved off App Store, the window after it is moved too)
    @Test func testEdgesThatArentDraggedChangeNothing() async throws {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        appStore(1, root) // Tiles of 640
        let settings = systemSettings(2, root, width: 300)
        systemSettings(3, root, width: 400)
        try await layoutTwice(workspace)
        assertEquals(settings.observedFrame, rect(1000, 0, 300, 1079))

        settings.axRectForTest = rect(1000, 0, 300, 900) // Its bottom edge is dragged, there is nothing below it
        try await resizeWithMouse(settings)
        try await resetManipulatedWithMouseIfPossible()
        assertEquals(root.children.map { $0.getWeight(.h) }, [1, 1, 1])
    }
}
