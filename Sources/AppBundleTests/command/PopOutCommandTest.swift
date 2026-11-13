@testable import AppBundle
import Common
import CoreGraphics
import Testing

/// A window pops out of the layout (floating, pinned, in the middle of the monitor) and back into its tile, like Omarchy's
/// "pop window out". The test monitor is 1920x1080: a popped out window is 1300x900 at 310, 90
@MainActor
@Suite(.serializedGlobally)
struct PopOutCommandTest {
    init() { setUpWorkspacesForTests() }

    private let popped = Rect(topLeftX: 310, topLeftY: 90, width: 1300, height: 900)

    @discardableResult
    private func run(_ command: String) async -> CmdResult {
        await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
    }

    @Test func testParse() {
        testParseSingleCommandSucc("pop-out", PopOutCmdArgs(rawArgs: [], toggle: .toggle))
        testParseSingleCommandSucc("pop-out off", PopOutCmdArgs(rawArgs: [], toggle: .off))
    }

    @Test func testATileGoesBackToItsPlace() async throws {
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let workspace = Workspace.get(byName: name)
        var window: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                window = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 2)
                TestWindow.new(id: 3, parent: $0, adaptiveWeight: 1)
            }
        }
        let tiles = root.layoutDescription
        #expect(window.focusWindow())

        await run("pop-out")
        workspace.normalizeContainers()
        try await workspace.layoutWorkspace()
        assertEquals(window.isFloating, true)
        assertEquals(window.isPinned, true)
        assertEquals(window.axRectForTest, popped)

        await run("pop-out")
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.layoutDescription, tiles)
        assertEquals(window.getWeight(.v), 2)
        assertEquals(window.isPinned, false)
    }

    /// The focus commands see the floating windows as tiles for a moment: the popped out window stays popped out, and
    /// remembers its tile
    @Test func testFocusDoesNotEndIt() async throws {
        let workspace = Workspace.get(byName: name)
        var window: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                window = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 2)
                TestWindow.new(id: 3, parent: $0, adaptiveWeight: 1)
            }
        }
        let tiles = root.layoutDescription
        #expect(window.focusWindow())
        await run("pop-out")
        try await workspace.layoutWorkspace()

        await run("focus --window-id 1")
        await run("focus right")
        await run("focus --window-id 2")
        assertEquals(window.isPinned, true)
        assertEquals(window.isFloating, true)

        await run("pop-out")
        assertEquals(root.layoutDescription, tiles)
        assertEquals(window.getWeight(.v), 2)
    }

    /// Moved and resized while it was popped out: it pops out there again
    @Test func testItPopsOutWhereItWas() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        #expect(window.focusWindow())
        await run("pop-out")
        try await workspace.layoutWorkspace()
        let moved = Rect(topLeftX: 100, topLeftY: 200, width: 800, height: 600)
        window.axRectForTest = moved
        try await workspace.layoutWorkspace() // Floating windows are read by every layout
        await run("pop-out")
        try await workspace.layoutWorkspace()
        assertEquals(window.isFloating, false)

        await run("pop-out")
        try await workspace.layoutWorkspace()
        assertEquals(window.axRectForTest, moved)
    }

    @Test func testAFloatingWindowGoesBackToWhereItWas() async throws {
        let workspace = Workspace.get(byName: name)
        let frame = Rect(topLeftX: 40, topLeftY: 50, width: 400, height: 300)
        let window = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer, rect: frame)
        #expect(window.focusWindow())
        try await workspace.layoutWorkspace()
        await run("pop-out on")
        try await workspace.layoutWorkspace()
        assertEquals(window.axRectForTest, popped)
        await run("pop-out off")
        try await workspace.layoutWorkspace()
        assertEquals(window.axRectForTest, frame)
        assertEquals(window.isFloating, true)
        assertEquals(window.isPinned, false)
    }

    /// It came along to the workspace that is shown now: it's a tile there
    @Test func testItComesAlongAndIsATileWhereItIs() async {
        let first = Workspace.get(byName: "A")
        let window = TestWindow.new(id: 1, parent: first.rootTilingContainer)
        TestWindow.new(id: 2, parent: first.rootTilingContainer)
        #expect(window.focusWindow())
        await run("pop-out")
        await run("workspace B")
        Workspace.movePinnedWindowsToVisibleWorkspaces()
        let second = Workspace.get(byName: "B")
        assertEquals(window.nodeWorkspace, second)

        #expect(window.focusWindow())
        await run("pop-out")
        assertEquals(second.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))
        assertEquals(first.rootTilingContainer.layoutDescription, .h_tiles([.window(2)]))
    }

    @Test func testOnAFloatingWorkspaceItFloatsLikeTheOthers() async {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        #expect(window.focusWindow())
        await run("pop-out")
        await run("workspace-layout floating")
        await run("pop-out")
        assertEquals(window.isPinned, false)
        assertEquals(window.isFloatedByWorkspaceLayout, true)
    }

    /// Made a tile with `layout tiling` meanwhile: it isn't popped out anymore, the command pops it out again
    @Test func testTiledMeanwhile() async {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        #expect(window.focusWindow())
        await run("pop-out")
        await run("layout tiling")
        assertEquals(window.isFloating, false)
        await run("pop-out")
        assertEquals(window.isFloating, true)
        assertEquals(window.isPinned, true)
    }

    /// A popped out window is still popped out after a restart of MarSpace
    @Test func testPersisted() throws {
        let placements = [
            WindowPlacement(nativeWindowId: 1, pid: 100, workspace: "1", isFloating: true, isPinned: true, poppedOutOfTile: true),
            WindowPlacement(nativeWindowId: 2, pid: 100, workspace: "1", isFloating: true, isPinned: true, poppedOutOfTile: false),
            WindowPlacement(nativeWindowId: 3, pid: 100, workspace: "1", isFloating: true, isPinned: true),
        ]
        let snapshot = try #require(WindowPlacementSnapshot(data: WindowPlacementSnapshot.encode(placements, bootSession: 1)))
        assertEquals(snapshot.all, placements)
    }
}
