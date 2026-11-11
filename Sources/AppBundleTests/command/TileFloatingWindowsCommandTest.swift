@testable import AppBundle
import Common
import Testing

/// All floating windows of a workspace are made tiling again, e.g. after they were made floating by mistake
@MainActor
@Suite(.serializedGlobally)
struct TileFloatingWindowsCommandTest {
    init() { setUpWorkspacesForTests() }

    @Test func testParse() {
        testParseSingleCommandSucc("tile-floating-windows", TileFloatingWindowsCmdArgs(rawArgs: []))
        assertEquals(parseCommand("tile-floating-windows all").errorOrNil, "ERROR: Unknown argument 'all'")
    }

    @Test func testFloatingWindowsOfTheWorkspaceAreTiled() async {
        let workspace = Workspace.get(byName: name)
        let tiling = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        let pinned = TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)
        pinned.isPinned = true
        let other = Workspace.get(byName: "other")
        TestWindow.new(id: 4, parent: other.floatingWindowsContainer)
        #expect(tiling.focusWindow())

        let result = await parseCommand("tile-floating-windows").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(workspace.floatingWindows.map(\.windowId), [])
        assertEquals(Set(workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId)), [1, 2, 3])
        assertEquals(pinned.isPinned, false) // Only a floating window can be pinned
        assertEquals(other.floatingWindows.map(\.windowId), [4])

        await parseCommand("tile-floating-windows --workspace other").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(other.floatingWindows.map(\.windowId), [])
        assertEquals(other.rootTilingContainer.layoutDescription, .h_tiles([.window(4)]))
    }

    @Test func testNothingToTile() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        #expect(workspace.focusWorkspace())
        let result = await parseCommand("tile-floating-windows").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    /// Windows that were made floating (`layout floating`) go back to their places in the layout, with their sizes
    @Test func testWindowsGoBackToTheirPlaces() async {
        config.newWindowPlacement = .dwindle // A new window would split the most recent window
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 2).apply {
                TestWindow.new(id: 2, parent: $0, adaptiveWeight: 3)
                TestWindow.new(id: 3, parent: $0, adaptiveWeight: 1)
            }
            TestWindow.new(id: 4, parent: $0, adaptiveWeight: 1)
        }
        let expected = LayoutDescription.h_tiles([.window(1), .v_tiles([.window(2), .window(3)]), .window(4)])
        assertEquals(workspace.rootTilingContainer.layoutDescription, expected)

        for id in [2, 4, 1] { // 4 is the most recent window then: as new windows, the others would split it
            await parseCommand("layout floating --window-id \(id)").cmdOrDie.run(.defaultEnv, .emptyStdin)
            workspace.normalizeContainers()
        }
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(3)]))

        #expect(workspace.focusWorkspace())
        await parseCommand("tile-floating-windows").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        let root = workspace.rootTilingContainer
        assertEquals(root.layoutDescription, expected)
        assertEquals(root.children.map { $0.getWeight(.h) }, [1, 2, 1])
        assertEquals((root.children[1] as? TilingContainer)?.children.map { $0.getWeight(.v) }, [3, 1])
    }

    /// `layout tiling` of a single window does the same. A floating window that was moved to another workspace has no
    /// place there: it's placed like a new window
    @Test func testLayoutTilingGoesBackToThePlace() async {
        let workspace = Workspace.get(byName: name)
        let other = Workspace.get(byName: "other")
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 3)
            TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1)
            TestWindow.new(id: 3, parent: $0, adaptiveWeight: 1)
        }
        TestWindow.new(id: 4, parent: other.rootTilingContainer)

        await parseCommand("layout floating --window-id 1").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await parseCommand("layout floating --window-id 2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await parseCommand("layout tiling --window-id 1").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(3)]))
        assertEquals(workspace.rootTilingContainer.children.map { $0.getWeight(.h) }, [3, 1])

        await parseCommand("move-node-to-workspace --window-id 2 other").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(other.floatingWindows.map(\.windowId), [2])
        await parseCommand("tile-floating-windows --workspace other").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(other.rootTilingContainer.layoutDescription, .h_tiles([.window(4), .window(2)]))
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .window(3)]))
    }
}
