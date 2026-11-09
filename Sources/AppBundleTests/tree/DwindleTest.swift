@testable import AppBundle
import Common
import Testing

private let wideRect = Rect(topLeftX: 0, topLeftY: 0, width: 800, height: 400)
private let tallRect = Rect(topLeftX: 0, topLeftY: 0, width: 400, height: 800)

@MainActor
@Suite(.serializedGlobally)
struct DwindleTest {
    init() {
        setUpWorkspacesForTests()
        config.newWindowPlacement = .dwindle
        // Dwindle relies on normalizations to collapse splits back
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
    }

    @Test func testParseConfig() {
        assertEquals(parseConfig("").config.newWindowPlacement, .i3)
        let result = parseConfig("new-window-placement = 'dwindle'")
        assertEquals(result.errors, [])
        assertEquals(result.config.newWindowPlacement, .dwindle)

        assertEquals(
            parseConfig("new-window-placement = 'spiral'").strErrors,
            ["[ERROR] new-window-placement: Can't parse new window placement 'spiral'. Possible values: (i3|dwindle)"],
        )
    }

    @Test func testThirdWindowSplitsMostRecentWindow_alternatesOrientationWithoutRects() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        assertEquals(TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer).focusWindow(), true)

        await parseCommand("layout tiling").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))

        // The fourth window splits the third one, and the orientation keeps alternating
        assertEquals(TestWindow.new(id: 4, parent: workspace.floatingWindowsContainer).focusWindow(), true)
        await parseCommand("layout tiling").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .h_tiles([.window(3), .window(4)])])]))
    }

    @Test func testTallAnchorIsSplitTopToBottom() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0).lastAppliedLayoutPhysicalRect = tallRect
        }
        assertEquals(TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer).focusWindow(), true)

        await parseCommand("layout tiling").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))
    }

    @Test func testWideAnchorIsSplitSideBySide() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0).lastAppliedLayoutPhysicalRect = wideRect
        }
        assertEquals(TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer).focusWindow(), true)

        await parseCommand("layout tiling").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        // Same orientation as the parent. The new window takes half of the anchor's space instead of nesting
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
        assertEquals(root.children.map { $0.getWeight(.h) }, [1, 0.5, 0.5])
    }

    @Test func testSecondWindowPicksRootOrientationByAspectRatio() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0).lastAppliedLayoutPhysicalRect = tallRect
        }
        assertEquals(TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer).focusWindow(), true)

        await parseCommand("layout tiling").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(root.layoutDescription, .v_tiles([.window(1), .window(2)]))
    }

    @Test func testAccordionIsNotSplit() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            $0.layout = .accordion
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        assertEquals(TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer).focusWindow(), true)

        await parseCommand("layout tiling").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(root.layoutDescription, .h_accordion([.window(1), .window(2), .window(3)]))
    }

    @Test func testClosingTheNewWindowCollapsesTheSplit() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        let window3 = TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)
        assertEquals(window3.focusWindow(), true)
        await parseCommand("layout tiling").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))

        window3.closeAxWindow()
        workspace.normalizeContainers()
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
        assertEquals(root.children.map { $0.getWeight(.h) }, [1, 1])
    }

    @Test func testMoveNodeToWorkspaceSplitsTargetWorkspaceMostRecentWindow() async {
        let workspaceA = Workspace.get(byName: "a")
        let workspaceB = Workspace.get(byName: "b")
        let rootB = workspaceB.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0) // The most recent window
            TestWindow.new(id: 3, parent: $0)
        }
        rootB.children[1].markAsMostRecentChild()
        workspaceA.rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 4, parent: $0).focusWindow(), true)
        }

        await parseCommand("move-node-to-workspace b").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspaceA.normalizeContainers()
        workspaceB.normalizeContainers()
        #expect(workspaceA.isEffectivelyEmpty)
        assertEquals(rootB.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(4)]), .window(3)]))
    }

    @Test func testMoveNodeToWorkspaceInI3ModeAppendsToRoot() async {
        config.newWindowPlacement = .i3
        let workspaceB = Workspace.get(byName: "b")
        let rootB = workspaceB.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        rootB.children[0].markAsMostRecentChild()
        Workspace.get(byName: "a").rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 3, parent: $0).focusWindow(), true)
        }

        await parseCommand("move-node-to-workspace b").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspaceB.normalizeContainers()
        assertEquals(rootB.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
    }

    @Test func testSplitIsSkippedIfWindowWasMovedAfterAnchorWasCaptured() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        let window3 = TestWindow.new(id: 3, parent: root)
        let anchor = window3.dwindleAnchor
        assertEquals((anchor as? Window)?.windowId, 2)

        // E.g., on-window-detected callback moved the window to another workspace
        window3.bind(to: Workspace.get(byName: "other").rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        window3.dwindleSplit(anchor)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }
}
