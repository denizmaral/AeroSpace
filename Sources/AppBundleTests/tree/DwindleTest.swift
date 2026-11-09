@testable import AppBundle
import Common
import Testing

// The test monitor is 1920x1080, see testMonitorInfoRect
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
        assertEquals(parseConfig("").config.newWindowPlacement, .dwindle)
        assertEquals(parseConfig("new-window-placement = 'i3'").config.newWindowPlacement, .i3)
        let result = parseConfig("new-window-placement = 'balanced'")
        assertEquals(result.errors, [])
        assertEquals(result.config.newWindowPlacement, .balanced)

        assertEquals(
            parseConfig("new-window-placement = 'spiral'").strErrors,
            ["[ERROR] new-window-placement: Can't parse new window placement 'spiral'. Possible values: (i3|dwindle|balanced)"],
        )
    }

    @Test func testThirdWindowSplitsMostRecentWindow_orientationAlternates() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }

        // Window 2 is 960x1080 (tall)
        await tileNewWindow(3, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))

        // Window 3 is 960x540 (wide)
        await tileNewWindow(4, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .h_tiles([.window(3), .window(4)])])]))
    }

    @Test func testOrientationIsComputedFromTheTree_notFromStaleRects() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            // Stale rect from the time when window 2 was alone
            TestWindow.new(id: 2, parent: $0).lastAppliedLayoutPhysicalRect = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        }

        await tileNewWindow(3, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))
    }

    @Test func testWideAnchorInHorizontalContainer_halvesTheWeight() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 420)
            TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1500) // 1500x1080 (wide)
        }

        await tileNewWindow(3, workspace)
        // Same orientation as the parent. The new window takes half of the anchor's space instead of nesting
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
        assertEquals(root.children.map { $0.getWeight(.h) }, [420, 750, 750])
    }

    @Test func testSecondWindowPicksRootOrientationByAspectRatio() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            $0.changeOrientation(.v)
            TestWindow.new(id: 1, parent: $0) // The whole 1920x1080 monitor (wide)
        }

        await tileNewWindow(2, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    @Test func testAccordionIsNotSplit() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            $0.layout = .accordion
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }

        await tileNewWindow(3, workspace)
        assertEquals(root.layoutDescription, .h_accordion([.window(1), .window(2), .window(3)]))
    }

    @Test func testClosingTheNewWindowCollapsesTheSplit() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        let window3 = await tileNewWindow(3, workspace)
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

    @Test func testBalanced_fourWindowsMakeGrid() async {
        config.newWindowPlacement = .balanced
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
        }

        await tileNewWindow(2, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
        await tileNewWindow(3, workspace) // Windows 1 and 2 have the same size. The most recent window 2 is split
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))
        await tileNewWindow(4, workspace) // Window 1 is the largest, even though it's not the most recent
        assertEquals(root.layoutDescription, .h_tiles([.v_tiles([.window(1), .window(4)]), .v_tiles([.window(2), .window(3)])]))

        // All windows have the same size. The most recent window 4 is split
        await tileNewWindow(5, workspace)
        assertEquals(
            root.layoutDescription,
            .h_tiles([.v_tiles([.window(1), .h_tiles([.window(4), .window(5)])]), .v_tiles([.window(2), .window(3)])]),
        )
    }

    @Test func testDwindle_fourWindowsMakeSpiral() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
        }

        await tileNewWindow(2, workspace)
        await tileNewWindow(3, workspace)
        await tileNewWindow(4, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .h_tiles([.window(3), .window(4)])])]))
    }
}

/// Emulates a new tiling window: the window appears as a focused floating window and becomes tiling
@discardableResult
@MainActor
private func tileNewWindow(_ id: OpaqueWindowId, _ workspace: Workspace) async -> TestWindow {
    let window = TestWindow.new(id: id, parent: workspace.floatingWindowsContainer)
    assertEquals(window.focusWindow(), true)
    await parseCommand("layout tiling").cmdOrDie.run(.defaultEnv, .emptyStdin)
    workspace.normalizeContainers()
    return window
}
