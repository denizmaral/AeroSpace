@testable import AppBundle
import Common
import CoreGraphics
import Testing

/// The columns of a scrolling workspace lie on a strip that can be longer than the screen, the screen shows the part with
/// the most recent column (see Layout.scrolling). The test monitor is 1920x1080 (the layout height is 1079), no gaps: a
/// column of weight 1 is 960 long. The columns that are off the screen wait in its bottom right corner
@MainActor
@Suite(.serializedGlobally)
struct ScrollingLayoutTest {
    init() { setUpWorkspacesForTests() }

    private let corner = CGPoint(x: 1919, y: 1079)

    private func scrollingWorkspace() -> (Workspace, TilingContainer) {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        root.layout = .scrolling
        return (workspace, root)
    }

    private func rect(_ x: CGFloat, _ width: CGFloat) -> Rect {
        Rect(topLeftX: x, topLeftY: 0, width: width, height: 1079)
    }

    @Test func testOneColumnFillsTheScreen() async throws {
        let (workspace, root) = scrollingWorkspace()
        let window = TestWindow.new(id: 1, parent: root)
        try await workspace.layoutWorkspace()
        assertEquals(window.lastAppliedLayoutPhysicalRect, rect(0, 1920))
    }

    @Test func testColumnsThatFitShareTheScreen() async throws {
        config.scrollingColumnWidth = 0.25
        let (workspace, root) = scrollingWorkspace()
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        try await workspace.layoutWorkspace()
        // Together a half of the screen: nothing is left empty
        assertEquals(first.lastAppliedLayoutPhysicalRect, rect(0, 960))
        assertEquals(second.lastAppliedLayoutPhysicalRect, rect(960, 960))
    }

    @Test func testTheScreenFollowsTheMostRecentColumn() async throws {
        let (workspace, root) = scrollingWorkspace()
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        let third = TestWindow.new(id: 3, parent: root)
        #expect(first.focusWindow())
        try await workspace.layoutWorkspace()
        assertEquals(first.lastAppliedLayoutPhysicalRect, rect(0, 960))
        assertEquals(second.lastAppliedLayoutPhysicalRect, rect(960, 960))
        // Off the screen: in the corner, with the size of its tile
        assertEquals(third.lastAppliedLayoutPhysicalRect, nil)
        assertEquals(third.axRectForTest, Rect(topLeftX: corner.x, topLeftY: corner.y, width: 960, height: 1079))

        #expect(third.focusWindow())
        try await workspace.layoutWorkspace()
        assertEquals(root.scrollOffset, 960)
        assertEquals(first.lastAppliedLayoutPhysicalRect, nil)
        assertEquals(second.lastAppliedLayoutPhysicalRect, rect(0, 960))
        assertEquals(third.lastAppliedLayoutPhysicalRect, rect(960, 960))
        assertEquals(third.axRectForTest, rect(960, 960))

        // The second column is on the screen: the screen stays where it is
        #expect(second.focusWindow())
        try await workspace.layoutWorkspace()
        assertEquals(root.scrollOffset, 960)
        assertEquals(second.lastAppliedLayoutPhysicalRect, rect(0, 960))
    }

    @Test func testAResizedColumnKeepsTheOthersAsTheyAre() async throws {
        let (workspace, root) = scrollingWorkspace()
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        #expect(first.focusWindow())
        try await workspace.layoutWorkspace()

        await parseCommand("resize width +200").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertEquals(first.lastAppliedLayoutPhysicalRect, rect(0, 1160))
        // Partly off the screen, beyond the right edge: no monitor is there
        assertEquals(second.lastAppliedLayoutPhysicalRect, rect(1160, 960))

        // Smaller columns share the screen again
        await parseCommand("resize width 760").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertEquals(first.getWeight(.h), 760.0 / 960.0)
        assertEquals(second.getWeight(.h), 1)

        await parseCommand("balance-sizes").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(first.getWeight(.h), 1)
    }

    @Test func testANewWindowIsAColumnAfterTheMostRecentColumn() {
        config.newWindowPlacement = .dwindle // Doesn't split anything on a scrolling workspace
        let (workspace, root) = scrollingWorkspace()
        let first = TestWindow.new(id: 1, parent: root)
        TilingContainer.newVTiles(parent: root, adaptiveWeight: 1.5).apply {
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        TestWindow.new(id: 4, parent: root)
        #expect(first.focusWindow())
        let new = TestWindow.new(id: 5, parent: workspace.floatingWindowsContainer)
        new.bindAsNewTilingWindow(to: workspace)
        assertEquals(root.layoutDescription, .h_scrolling([.window(1), .window(5), .v_tiles([.window(2), .window(3)]), .window(4)]))
        assertEquals(new.getWeight(.h), 1)
    }

    @Test func testTheSingleColumnStaysAColumn() {
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let (workspace, root) = scrollingWorkspace()
        TilingContainer.newVTiles(parent: root, adaptiveWeight: 1).apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        workspace.normalizeContainers()
        assertEquals(root.layoutDescription, .h_scrolling([.v_tiles([.window(1), .window(2)])]))
    }

    @Test func testTheLayoutOfTheColumnsCantBeChanged() async {
        let (_, root) = scrollingWorkspace()
        #expect(TestWindow.new(id: 1, parent: root).focusWindow())
        let result = await parseCommand("layout v_accordion").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(root.layout, .scrolling)
    }

    @Test func testListWindowsTellsTheScrollingLayout() async {
        let (_, root) = scrollingWorkspace()
        #expect(TestWindow.new(id: 1, parent: root).focusWindow())
        let result = await parseCommand("list-windows --focused --format %{window-layout}").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.stdout, ["h_scrolling"])
    }

    /// The screen slides along the strip: the windows move in steps, and end where the layout puts them
    @Test func testTheScreenSlides() async throws {
        config.animatesScrolling = true
        let (workspace, root) = scrollingWorkspace()
        let windows = (1 ... 3).map { TestWindow.new(id: OpaqueWindowId(UInt64($0)), parent: root) }
        #expect(windows[0].focusWindow())
        try await workspace.layoutWorkspace() // The first layout puts them in place
        let sentBefore = windows[2].sentFrames.count

        #expect(windows[2].focusWindow())
        try await workspace.layoutWorkspace()
        // It comes from where the previous offset put it: off the screen on the right
        assertEquals(windows[2].sentFrames.last?.topLeft, CGPoint(x: 1920, y: 0))
        try await workspace.layoutWorkspace() // A session that follows doesn't make it jump
        assertEquals(windows[2].sentFrames.last?.topLeft, CGPoint(x: 1920, y: 0))

        try await Task.sleep(for: .milliseconds(400))
        #expect(windows[2].sentFrames.count - sentBefore > 3, "\(windows[2].sentFrames.count - sentBefore)") // Steps between
        assertEquals(windows[2].axRectForTest, rect(960, 960))
        assertEquals(windows[1].axRectForTest, rect(0, 960))
        // It slid off the screen to the left, and waits in the corner then
        assertEquals(windows[0].axRectForTest, Rect(topLeftX: corner.x, topLeftY: corner.y, width: 960, height: 1079))
    }

    /// While MarSpace is disabled, every window is on the screen: no column waits in the corner
    @Test func testDisabledShowsEveryColumn() async throws {
        let (workspace, root) = scrollingWorkspace()
        let windows = (1 ... 3).map { TestWindow.new(id: OpaqueWindowId(UInt64($0)), parent: root) }
        TrayMenuModel.shared.isEnabled = false
        defer { TrayMenuModel.shared.isEnabled = true }
        try await workspace.layoutWorkspace()
        assertEquals(windows.map(\.lastAppliedLayoutPhysicalRect?.width), [640, 640, 640])
    }

    // MARK: - The strip

    /// Columns of 960 and a screen of 1920, without gaps
    private func strip(_ lengths: [CGFloat]) -> ScrollingStrip {
        ScrollingStrip(lengths: lengths, screen: 1920, gap: 0)
    }

    @Test func testTheOffsetMovesOnlyAsFarAsNeeded() {
        let strip = strip([960, 960, 960, 960])
        assertEquals(strip.offset(showing: 3, from: 0), 1920)
        assertEquals(strip.offset(showing: 2, from: 1920), 1920) // On the screen already
        assertEquals(strip.offset(showing: 1, from: 1920), 960)
        assertEquals(strip.offset(showing: 0, from: 960), 0)
        // Never beyond the end of the strip (e.g. a column was closed)
        assertEquals(strip.offset(showing: 3, from: 5000), 1920)
    }

    @Test func testAColumnBeyondAnEdgeWithAMonitorIsSqueezed() {
        let strip = strip([1160, 960])
        assertEquals(
            strip.placements(offset: 0, isStartEdgeFree: true, isEndEdgeFree: true),
            [.tile(start: 0, length: 1160), .tile(start: 1160, length: 960)],
        )
        // Another monitor is behind the right edge: the column must not reach there
        assertEquals(
            strip.placements(offset: 0, isStartEdgeFree: true, isEndEdgeFree: false),
            [.tile(start: 0, length: 1160), .tile(start: 1160, length: 760)],
        )
        // Less than a third of it would be on the screen: it waits in the corner
        assertEquals(
            ScrollingStrip(lengths: [1700, 960], screen: 1920, gap: 0).placements(offset: 0, isStartEdgeFree: true, isEndEdgeFree: false),
            [.tile(start: 0, length: 1700), .parked(start: 1700, length: 960)],
        )
    }

    @Test func testGapsAreBetweenTheColumnsOnly() {
        // A gap of 20: the strip shows 1940, a column of weight 1 is 970 with its gap, its tile is 950
        let strip = ScrollingStrip(lengths: [970, 970, 970], screen: 1920, gap: 20)
        assertEquals(
            strip.placements(offset: 0, isStartEdgeFree: true, isEndEdgeFree: true),
            [.tile(start: 0, length: 950), .tile(start: 970, length: 950), .parked(start: 1940, length: 950)],
        )
    }

    @Test func testTheScrollingLayoutIsPersisted() {
        let snapshot = PersistedTilingTree(
            workspace: "S",
            mostRecentWindow: 1,
            root: .init(orientation: .h, layout: .scrolling, weight: 1, children: [.window(id: 1, weight: 1.5)]),
        )
        assertEquals([PersistedTilingTree](decoding: [snapshot].encoded()), [snapshot])
    }
}
