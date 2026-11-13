@testable import AppBundle
import Common
import CoreGraphics
import Testing

/// A workspace tiles, scrolls or floats, and switching never loses the layout (see WorkspaceLayout). The test monitor is
/// 1920x1080: the floating layout puts a window that was a tile at 1100x734 in the middle, stepped by 24
@MainActor
@Suite(.serializedGlobally)
struct WorkspaceLayoutCommandTest {
    init() { setUpWorkspacesForTests() }

    @discardableResult
    private func run(_ command: String) async -> CmdResult {
        await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
    }

    /// What the refresh sessions do around a command
    private func session(_ workspace: Workspace) {
        Workspace.applyFloatingLayouts()
        workspace.normalizeContainers()
    }

    @Test func testParse() {
        testParseSingleCommandSucc("workspace-layout scrolling", WorkspaceLayoutCmdArgs(rawArgs: [], cycle: [.scrolling]))
        testParseSingleCommandSucc(
            "workspace-layout tiling scrolling floating",
            WorkspaceLayoutCmdArgs(rawArgs: [], cycle: [.tiling, .scrolling, .floating]),
        )
        testParseCommandFail(
            "workspace-layout tiles",
            msg: "ERROR: Can't parse 'tiles'\n       Possible values: (tiling|scrolling|floating)",
            exitCode: 2,
        )
        testParseCommandFail(
            "workspace-layout --fail-if-noop tiling floating",
            msg: "--fail-if-noop allows only one <layout> argument",
            exitCode: 2,
        )
    }

    /// Omarchy's cycle: tiling, scrolling, floating, and back to the tiles as they were
    @Test func testTheCycleGivesBackTheTiles() async {
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        config.newWindowPlacement = .dwindle
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 3).apply {
                TestWindow.new(id: 2, parent: $0, adaptiveWeight: 2)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 3, parent: $0, adaptiveWeight: 1)
                    TestWindow.new(id: 4, parent: $0, adaptiveWeight: 5)
                }
            }
        }
        let tiles: LayoutDescription = .h_tiles([.window(1), .v_tiles([.window(2), .h_tiles([.window(3), .window(4)])])])
        func weights() -> [CGFloat] {
            workspace.rootTilingContainer.allLeafWindowsRecursive.map { $0.getWeight(($0.parent as! TilingContainer).orientation) }
        }
        let tileWeights = weights()
        #expect(workspace.rootTilingContainer.allLeafWindowsRecursive[1].focusWindow())

        let cycle = "workspace-layout tiling scrolling floating"
        await run(cycle)
        session(workspace)
        assertEquals(workspace.workspaceLayout, .scrolling)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_scrolling([.window(1), .window(2), .window(3), .window(4)]))

        await run(cycle)
        session(workspace)
        assertEquals(workspace.workspaceLayout, .floating)
        assertEquals(workspace.rootTilingContainer.allLeafWindowsRecursive.count, 0)
        assertEquals(workspace.floatingWindows.map(\.windowId), [1, 2, 3, 4])
        assertEquals(workspace.floatingWindows.map(\.isFloatedByWorkspaceLayout), [true, true, true, true])

        await run(cycle)
        session(workspace)
        assertEquals(workspace.workspaceLayout, .tiling)
        assertEquals(workspace.rootTilingContainer.layoutDescription, tiles)
        assertEquals(weights(), tileWeights)
        assertEquals(workspace.floatingWindows.count, 0)
        assertEquals(workspace.rootTilingContainer.mostRecentWindowRecursive?.windowId, 2)
    }

    /// The columns as the user left them: a column that was moved stays there
    @Test func testTheColumnsComeBackAsTheyWere() async {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        #expect(workspace.rootTilingContainer.allLeafWindowsRecursive[0].focusWindow())
        await run("workspace-layout scrolling")
        await run("move right")
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_scrolling([.window(2), .window(1), .window(3)]))

        await run("workspace-layout tiling")
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
        await run("workspace-layout scrolling")
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_scrolling([.window(2), .window(1), .window(3)]))
    }

    /// The focus moved while the workspace was in another layout: the screen shows the focused column
    @Test func testTheFocusedColumnIsShown() async throws {
        let workspace = Workspace.get(byName: name)
        let windows = (1 ... 4).map { TestWindow.new(id: OpaqueWindowId(UInt64($0)), parent: workspace.rootTilingContainer) }
        #expect(windows[0].focusWindow())
        await run("workspace-layout scrolling")
        try await workspace.layoutWorkspace()

        await run("workspace-layout tiling")
        #expect(windows[3].focusWindow())
        await run("workspace-layout scrolling")
        try await workspace.layoutWorkspace()
        #expect(windows[3].lastAppliedLayoutPhysicalRect != nil) // On the screen, not in the corner
        assertEquals(workspace.rootTilingContainer.mostRecentWindowRecursive?.windowId, 4)

        await run("workspace-layout floating")
        #expect(windows[1].focusWindow())
        await run("workspace-layout scrolling")
        try await workspace.layoutWorkspace()
        #expect(windows[1].lastAppliedLayoutPhysicalRect != nil)
        assertEquals(workspace.rootTilingContainer.mostRecentWindowRecursive?.windowId, 2)
    }

    /// A window in macOS fullscreen while the workspace goes through all its layouts comes back as a tile or floating,
    /// like the other windows
    @Test func testAWindowAwayInMacosFullscreen() async throws {
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        config.automaticallyUnhideMacosHiddenApps = true // The hidden app check needs MacApp
        let workspace = Workspace.get(byName: name)
        var away: TestWindow!
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                away = TestWindow.new(id: 3, parent: $0)
            }
        }
        #expect(workspace.rootTilingContainer.allLeafWindowsRecursive[0].focusWindow())
        away.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()
        #expect(away.parent === workspace.macOsNativeFullscreenWindowsContainer)

        for layout in ["scrolling", "floating", "tiling", "scrolling"] {
            await run("workspace-layout \(layout)")
            session(workspace)
        }
        away.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()
        session(workspace)
        // Next to its neighbor, below it like in the tiles: a column with window 2
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_scrolling([.window(1), .v_tiles([.window(2), .window(3)])]))

        // Back while the workspace floats: it floats, and it's a tile again when the workspace tiles
        away.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()
        await run("workspace-layout floating")
        session(workspace)
        away.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()
        session(workspace)
        assertEquals(away.isFloatedByWorkspaceLayout, true)
        await run("workspace-layout tiling")
        session(workspace)
        assertEquals(workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId.rawId).sorted(), [1, 2, 3])
    }

    /// A popped out window floats on its own account: the workspace floats and tiles again meanwhile, it pops back into
    /// its tile
    @Test func testAPoppedOutWindow() async {
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let workspace = Workspace.get(byName: name)
        var popped: TestWindow!
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                popped = TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        let tiles = workspace.rootTilingContainer.layoutDescription
        #expect(popped.focusWindow())
        await run("pop-out")
        session(workspace)
        for layout in ["floating", "scrolling", "tiling"] {
            await run("workspace-layout \(layout)")
            session(workspace)
            assertEquals(popped.isPoppedOut, true)
            assertEquals(popped.isFloatedByWorkspaceLayout, false)
        }
        #expect(popped.focusWindow())
        await run("pop-out")
        session(workspace)
        assertEquals(workspace.rootTilingContainer.layoutDescription, tiles)
    }

    /// The screen shows the columns that it showed: the focused column isn't moved to an edge
    @Test func testTheScreenShowsTheSameColumns() async throws {
        let workspace = Workspace.get(byName: name)
        let windows = (1 ... 4).map { TestWindow.new(id: OpaqueWindowId(UInt64($0)), parent: workspace.rootTilingContainer) }
        #expect(windows[3].focusWindow())
        await run("workspace-layout scrolling")
        try await workspace.layoutWorkspace()
        #expect(windows[2].focusWindow()) // On the screen already: it stays where it is, on the left
        try await workspace.layoutWorkspace()
        assertEquals(windows[2].lastAppliedLayoutPhysicalRect?.topLeftX, 0)

        await run("workspace-layout tiling")
        await run("workspace-layout scrolling")
        try await workspace.layoutWorkspace()
        assertEquals(windows[2].lastAppliedLayoutPhysicalRect?.topLeftX, 0)
        assertEquals(windows[3].lastAppliedLayoutPhysicalRect?.topLeftX, 960)
    }

    @Test func testFloatingPutsTheTilesInTheMiddle() async throws {
        let workspace = Workspace.get(byName: name)
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let second = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        let dialog = TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer, rect: Rect(topLeftX: 5, topLeftY: 5, width: 300, height: 200))
        #expect(first.focusWindow())
        await run("workspace-layout floating")
        try await workspace.layoutWorkspace()
        assertEquals(first.axRectForTest, Rect(topLeftX: 362, topLeftY: 125, width: 1100, height: 734))
        assertEquals(second.axRectForTest, Rect(topLeftX: 386, topLeftY: 149, width: 1100, height: 734))
        assertEquals(dialog.isFloatedByWorkspaceLayout, false)

        // Where they were put, when the workspace floats again
        second.axRectForTest = Rect(topLeftX: 600, topLeftY: 300, width: 800, height: 500)
        try await workspace.layoutWorkspace() // Floating windows are read by every layout
        await run("workspace-layout tiling")
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(2)]))
        assertEquals(workspace.floatingWindows.map(\.windowId), [3]) // It floats on its own account
        await run("workspace-layout floating")
        try await workspace.layoutWorkspace()
        assertEquals(second.axRectForTest, Rect(topLeftX: 600, topLeftY: 300, width: 800, height: 500))
    }

    @Test func testWindowsThatComeToAFloatingWorkspaceFloat() async {
        let workspace = Workspace.get(byName: "F")
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        #expect(first.focusWindow())
        await run("workspace-layout floating")

        // A new window (placed as a tile, the window rules ran)
        let new = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        session(workspace)
        assertEquals(new.isFloatedByWorkspaceLayout, true)
        assertEquals(workspace.rootTilingContainer.allLeafWindowsRecursive.count, 0)

        // Moved to a workspace that tiles: a tile there
        await run("move-node-to-workspace --window-id 2 other")
        let other = Workspace.get(byName: "other")
        session(other)
        assertEquals(new.isFloatedByWorkspaceLayout, false)
        assertEquals(other.rootTilingContainer.layoutDescription, .h_tiles([.window(2)]))

        // And back: it floats again
        await run("move-node-to-workspace --window-id 2 F")
        session(workspace)
        assertEquals(new.isFloatedByWorkspaceLayout, true)
        assertEquals(workspace.floatingWindows.map(\.windowId), [1, 2])
    }

    @Test func testTheUserDecidesForAWindow() async {
        let workspace = Workspace.get(byName: name)
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let second = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        #expect(first.focusWindow())
        await run("workspace-layout floating")

        // A tile on the floating workspace
        await run("layout tiling")
        session(workspace)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))

        // Floating on its own account: it stays floating when the workspace tiles
        #expect(second.focusWindow())
        await run("layout floating")
        assertEquals(second.isFloatedByWorkspaceLayout, false)
        await run("workspace-layout tiling")
        session(workspace)
        assertEquals(workspace.floatingWindows.map(\.windowId), [2])
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))
    }

    /// The settings choose the layout of the workspaces that workspace-layout didn't switch
    @Test func testTheDefaultLayout() {
        var settings = Settings.defaults
        settings.general.defaultWorkspaceLayout = .scrolling
        settings.general.scrollingColumnWidth = 40
        config = settings.compile().config.with(\.defaultRootContainerOrientation, .horizontal)
        assertEquals(config.scrollingColumnWidth, 0.4)
        assertEquals(Workspace.get(byName: "S").workspaceLayout, .scrolling)

        config.defaultWorkspaceLayout = .floating
        let workspace = Workspace.get(byName: "F")
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        session(workspace)
        assertEquals(workspace.workspaceLayout, .floating)
        assertEquals(window.isFloatedByWorkspaceLayout, true)

        // The default tiles again: the windows that it floated are tiles
        config.defaultWorkspaceLayout = .tiling
        session(workspace)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))
    }

    @Test func testAnEmptyWorkspaceKeepsItsLayout() async {
        await run("workspace-layout --workspace S scrolling")
        Workspace.garbageCollectUnusedWorkspaces()
        #expect(!Workspace.all.contains { $0.name == "S" })
        assertEquals(Workspace.get(byName: "S").workspaceLayout, .scrolling)
    }

    @Test func testFailIfNoop() async {
        let result = await run("workspace-layout --fail-if-noop tiling")
        #expect(result.exitCode.rawValue != 0)
        assertEquals(result.stderr, [])
        assertEquals((await run("workspace-layout tiling")).stderr, ["The workspace is tiling already. Tip: use --fail-if-noop to exit with non-zero exit code"])
    }

    @Test func testListWorkspacesTellsTheLayout() async {
        await run("workspace-layout floating")
        assertEquals((await run("list-workspaces --focused --format %{workspace-layout}")).stdout, ["floating"])
    }
}
