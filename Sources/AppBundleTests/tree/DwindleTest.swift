@testable import AppBundle
import Common
import CoreGraphics
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

    @Test func testSplitIsSkippedIfWindowWasMovedAfterSplitWasCaptured() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        let window3 = TestWindow.new(id: 3, parent: root)
        let split = window3.captureDwindleSplit()
        #expect(split != nil)

        // E.g., on-window-detected callback moved the window to another workspace
        window3.bind(to: Workspace.get(byName: "other").rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        window3.applyDwindleSplit(split)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }

    @Test func testStaleSplitIsSkippedIfWindowWasRetiledNextToTheSameAnchor() async {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 420)
            TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1500) // 1500x1080 (wide)
        }
        let window3 = TestWindow.new(id: 3, parent: root)
        let split = window3.captureDwindleSplit()

        // E.g., on-window-detected callback: run = ['layout floating', 'layout tiling']. It splits window 2 on its own
        assertEquals(window3.focusWindow(), true)
        await parseCommand("layout floating").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await parseCommand("layout tiling").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(root.children.map { $0.getWeight(.h) }, [420, 750, 750])

        window3.applyDwindleSplit(split) // Must not split window 2 for the second time
        assertEquals(root.children.map { $0.getWeight(.h) }, [420, 750, 750])
    }

    @Test func testInvisibleWindowDoesNotSplit() {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 420)
            TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1500)
        }
        // E.g., a window on another macOS Space
        let window3 = TestWindow.new(id: 3, parent: root)
        window3.lifeStatus = .invisible

        window3.applyDwindleSplit(window3.captureDwindleSplit())
        assertEquals(root.children.map { $0.getWeight(.h) }, [420, 1500, 1])
    }

    @Test func testPopupPromotedToWindow_splitIsAppliedAfterCallbacks() async throws {
        config.onWindowDetected = parseConfig(
            """
            [[on-window-detected]]
            if.app-id = 'bobko.AeroSpace.test-app'
            run = 'move-node-to-workspace B'
            """,
        ).config.onWindowDetected
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 420)
            TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1500)
        }
        let popup = TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)

        // The same steps as in validateStillPopups
        let split = try await popup.relayoutWindowDeferringDwindleSplit(on: workspace, .nonCancellable, forceTile: true)
        await runOnWindowDetected(ifConventional: popup)
        popup.applyDwindleSplit(split)

        assertEquals(popup.nodeWorkspace?.name, "B")
        workspace.normalizeContainers()
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
        assertEquals(root.children.map { $0.getWeight(.h) }, [420, 1500])
    }

    @Test func testClosingTheNewWindowGivesTheWeightBack_sameOrientation() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 420)
            TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1500) // 1500x1080 (wide)
        }
        let window3 = await tileNewWindow(3, workspace)
        assertEquals(root.children.map { $0.getWeight(.h) }, [420, 750, 750])

        window3.closeAxWindow()
        workspace.normalizeContainers()
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
        assertEquals(root.children.map { $0.getWeight(.h) }, [420, 1500])
    }

    /// Regression: binding to a container whose lifeStatus is stale (mustBeFlattened) from the previous normalization
    @Test func testNormalizationFlattensIntoMustBeFlattenedContainer() {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 1, parent: root)
        let vContainer = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        TestWindow.new(id: 5, parent: vContainer).lifeStatus = .invisible // E.g. a background native tab
        let hContainer = TilingContainer.newHTiles(parent: vContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        let window2 = TestWindow.new(id: 2, parent: vContainer)
        TestWindow.new(id: 3, parent: hContainer)
        let window4 = TestWindow.new(id: 4, parent: hContainer)
        workspace.normalizeContainers()

        window2.closeAxWindow()
        workspace.normalizeContainers() // vContainer: [5 (invisible), hContainer] -> mustBeFlattened
        assertEquals(vContainer.lifeStatus, .mustBeFlattened)

        window4.closeAxWindow()
        workspace.normalizeContainers() // hContainer: [3] -> window 3 is flattened into vContainer
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .h_tiles([.window(5), .window(3)])]))
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

/// Windows detected at the same time: the callbacks of a detected window suspend (e.g. on-window-detected reads the
/// window title), and another session detects the next window meanwhile
@MainActor
@Suite(.serializedGlobally)
struct DwindleConcurrentDetectionTest {
    init() {
        setUpWorkspacesForTests()
        config.newWindowPlacement = .dwindle
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
    }

    /// Binds the windows the same way as newly detected windows, the callbacks didn't finish yet
    private func detect(_ ids: [OpaqueWindowId], _ workspace: Workspace) async throws -> [(TestWindow, DwindleSplit?)] {
        var result: [(TestWindow, DwindleSplit?)] = []
        for id in ids {
            let window = TestWindow.new(id: id, parent: workspace.floatingWindowsContainer)
            result.append((window, try await window.relayoutWindowDeferringDwindleSplit(on: workspace, .nonCancellable, forceTile: true)))
        }
        return result
    }

    /// The same result as if the windows were detected one after another, whichever callbacks finish first
    @Test(arguments: [false, true])
    func testSameResultAsDetectedOneAfterAnother(callbacksOfTheLaterWindowFinishFirst: Bool) async throws {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        let detected = try await detect([3, 4], workspace)
        if callbacksOfTheLaterWindowFinishFirst {
            detected[1].0.applyDwindleSplit(detected[1].1)
            // Waits for window 3: window 4 is put next to window 3, window 3 must split window 2 first
            assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3), .window(4)]))
            detected[0].0.applyDwindleSplit(detected[0].1)
        } else {
            for (window, split) in detected { window.applyDwindleSplit(split) }
        }
        workspace.normalizeContainers()
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .h_tiles([.window(3), .window(4)])])]))
        assertEquals(root.children.map { $0.getWeight(.h) }, [1, 1])
        #expect(dwindleSplitQueue.isEmpty)

        // The same as one after another
        setUpWorkspacesForTests()
        config.newWindowPlacement = .dwindle
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let workspace2 = Workspace.get(byName: name)
        let root2 = workspace2.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        for id: OpaqueWindowId in [3, 4] {
            for (window, split) in try await detect([id], workspace2) { window.applyDwindleSplit(split) }
        }
        workspace2.normalizeContainers()
        assertEquals(root2.layoutDescription, root.layoutDescription)
    }

    /// E.g. the session of window 3 is canceled before its callbacks
    @Test func testDiscardedSplitDoesntBlockLaterSplits() async throws {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        let detected = try await detect([3, 4], workspace)
        detected[0].1?.discard()
        detected[1].0.applyDwindleSplit(detected[1].1)
        workspace.normalizeContainers()
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .v_tiles([.window(3), .window(4)])]))
        #expect(dwindleSplitQueue.isEmpty)
    }

    /// E.g. on-window-detected of window 3 moves it to another workspace. Its split is never applied, nothing waits for it
    @Test func testStaleSplitDoesntBlockLaterSplits() async throws {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        let detected = try await detect([3, 4], workspace)
        detected[0].0.bind(to: Workspace.get(byName: "other").rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        detected[1].0.applyDwindleSplit(detected[1].1)
        workspace.normalizeContainers()
        // Window 4 was put next to window 3, window 3 is gone. Window 4 splits nothing
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(4)]))
        #expect(dwindleSplitQueue.isEmpty)
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

@MainActor
@Suite(.serializedGlobally)
struct DwindleMinimumSizeTest {
    init() {
        setUpWorkspacesForTests()
        config.newWindowPlacement = .dwindle
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
    }

    @Test func testSplitDirectionThatFitsTheMinimumSize() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            // 1000pt minimum width doesn't fit into a half of the 1920pt wide monitor
            TestWindow.new(id: 1, parent: $0).learnedMinimumSize = CGSize(width: 1000, height: 0)
        }
        assertEquals(TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer).focusWindow(), true)
        await parseCommand("layout tiling").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(root.layoutDescription, .v_tiles([.window(1), .window(2)]))
    }

    @Test func testPreferredDirectionWhenNothingFits() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0).learnedMinimumSize = CGSize(width: 1000, height: 600)
        }
        assertEquals(TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer).focusWindow(), true)
        await parseCommand("layout tiling").cmdOrDie.run(.defaultEnv, .emptyStdin)
        workspace.normalizeContainers()
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
    }
}
