@testable import AppBundle
import Common
import Testing

/// A tiling window that leaves the tiling tree for macOS native fullscreen comes back to the same place
@MainActor
@Suite(.serializedGlobally)
struct TilingSlotTest {
    init() {
        setUpWorkspacesForTests()
        config.newWindowPlacement = .dwindle // A new window would split the most recent window
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        config.automaticallyUnhideMacosHiddenApps = true // The hidden app check needs MacApp
    }

    /// The window enters native fullscreen, the session normalizes the containers, `meanwhile` runs, the window leaves
    /// native fullscreen
    private func fullscreenRoundTrip(_ window: TestWindow, _ workspace: Workspace, meanwhile: () -> Void = {}) async throws {
        window.isMacosFullscreenForTest = true
        try await normalizeLayoutReason()
        #expect(window.parent === workspace.macOsNativeFullscreenWindowsContainer)
        workspace.normalizeContainers()
        meanwhile()
        window.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()
        workspace.normalizeContainers()
    }

    @Test func testSameContainer() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window2: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 500)
            window2 = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 900)
            TestWindow.new(id: 3, parent: $0, adaptiveWeight: 520)
        }
        try await fullscreenRoundTrip(window2, workspace) {
            assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(3)]))
        }
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
        assertEquals(root.children.map { $0.getWeight(.h) }, [500, 900, 520])
    }

    /// The normalization would flatten the container of the window (a single window is left). It's kept for the window
    @Test func testFlattenedContainer() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window3: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                window3 = TestWindow.new(id: 3, parent: $0)
            }
        }
        try await fullscreenRoundTrip(window3, workspace) {
            // The container is kept for window 3 (mustBeFlattened: transparent, it takes the orientation of its parent)
            assertEquals(root.layoutDescription, .h_tiles([.window(1), .h_tiles([.window(2)])]))
            root.children.first?.markAsMostRecentChild() // A new window would split window 1
        }
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))
    }

    @Test func testFlattenedContainer_firstChild() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window2: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                window2 = TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        try await fullscreenRoundTrip(window2, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))
    }

    /// E.g. Zen Browser next to two terminals. The normalization would flatten the container of the terminals into the root
    @Test func testFlattenedRoot() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window1: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            window1 = TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        try await fullscreenRoundTrip(window1, workspace) {
            assertEquals(root.layoutDescription, .h_tiles([.v_tiles([.window(2), .window(3)])])) // Not flattened into the root
        }
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))
    }

    private func setFullscreen(_ windows: [TestWindow], _ isFullscreen: Bool, _ workspace: Workspace) async throws {
        for window in windows { window.isMacosFullscreenForTest = isFullscreen }
        try await normalizeLayoutReason()
        workspace.normalizeContainers()
    }

    /// E.g. two windows of the app are hidden or minimized ("Minimize All"). They come back in their order whichever
    /// comes back first
    @Test(arguments: [false, true])
    func testTwoSiblings(reversedExit: Bool) async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var windows: [TestWindow] = []
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 500)
            windows.append(TestWindow.new(id: 2, parent: $0, adaptiveWeight: 900))
            windows.append(TestWindow.new(id: 3, parent: $0, adaptiveWeight: 520))
        }
        try await setFullscreen([windows[0]], true, workspace)
        try await setFullscreen([windows[1]], true, workspace)
        for window in reversedExit ? windows.reversed() : windows {
            try await setFullscreen([window], false, workspace)
        }
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
        assertEquals(root.children.map { $0.getWeight(.h) }, [500, 900, 520])
    }

    /// Window 1 leaves the root with a single container, then window 2 leaves the container
    @Test func testFlattenedRootAndAnotherWindow() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window1: TestWindow!
        var window2: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            window1 = TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                window2 = TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        try await setFullscreen([window1], true, workspace)
        try await setFullscreen([window2], true, workspace)
        try await setFullscreen([window1], false, workspace)
        try await setFullscreen([window2], false, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))
    }

    /// The root would take the layout of the container (the orientation is the same without the opposite orientation
    /// normalization)
    @Test func testFlattenedRootWithAnotherLayout() async throws {
        config.enableNormalizationOppositeOrientationForNestedContainers = false
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window1: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            window1 = TestWindow.new(id: 1, parent: $0)
            TilingContainer(parent: $0, adaptiveWeight: 1, .h, .accordion, index: INDEX_BIND_LAST).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        try await fullscreenRoundTrip(window1, workspace) {
            assertEquals(root.layoutDescription, .h_tiles([.h_accordion([.window(2), .window(3)])])) // Not flattened into the root
        }
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .h_accordion([.window(2), .window(3)])]))
    }

    /// Dwindle: window 3 split window 2 in half. Window 3 is closed while window 2 is in native fullscreen, window 2
    /// gets its weight back
    @Test func testWeightOfClosedWindowGoesBackToTheSlot() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window2: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 420)
            window2 = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1500) // 1500x1080 (wide)
        }
        let window3 = TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)
        window3.bindAsNewTilingWindow(to: workspace)
        assertEquals(root.children.map { $0.getWeight(.h) }, [420, 750, 750])
        try await fullscreenRoundTrip(window2, workspace) {
            window3.closeAxWindow()
        }
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
        assertEquals(root.children.map { $0.getWeight(.h) }, [420, 1500])
    }

    /// Both windows of a container are fullscreen. The window that comes back first is alone in the container for a while
    @Test func testNeighborIsStillAway() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window2: TestWindow!
        var window3: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                window2 = TestWindow.new(id: 2, parent: $0)
                window3 = TestWindow.new(id: 3, parent: $0)
            }
        }
        try await setFullscreen([window3], true, workspace)
        try await setFullscreen([window2], true, workspace)
        try await setFullscreen([window3], false, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .h_tiles([.window(3)])])) // The container waits for window 2
        try await setFullscreen([window2], false, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))
    }

    /// E.g. both windows of the container belong to the app that is hidden. The empty container is kept for them
    @Test(arguments: [false, true])
    func testWholeContainerLeaves(reversedExit: Bool) async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var windows: [TestWindow] = []
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 10, parent: $0)
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                windows.append(TestWindow.new(id: 2, parent: $0))
                windows.append(TestWindow.new(id: 3, parent: $0))
            }
        }
        try await setFullscreen(windows, true, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(10), .window(1), .h_tiles([])])) // The empty container is kept
        for window in reversedExit ? windows.reversed() : windows {
            root.children.first?.markAsMostRecentChild() // A new window would split window 10
            try await setFullscreen([window], false, workspace) // The normalization runs in between
        }
        assertEquals(root.layoutDescription, .h_tiles([.window(10), .window(1), .v_tiles([.window(2), .window(3)])]))
    }

    @Test func testWholeContainerComesBackInOneSession() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var windows: [TestWindow] = []
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                windows.append(TestWindow.new(id: 2, parent: $0))
                windows.append(TestWindow.new(id: 3, parent: $0))
            }
        }
        try await setFullscreen(windows, true, workspace)
        try await setFullscreen(windows, false, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))
    }

    /// The same steps as the macos-native-fullscreen command (it can't run with TestWindow): the window is bound to the
    /// fullscreen container before the native state is detected
    @Test func testFullscreenCommand() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window2: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            window2 = TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        window2.bindToMacosNativeStateContainer(workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: 1)
        window2.isMacosFullscreenForTest = true
        try await normalizeLayoutReason() // layoutReason = .macos(prevParentKind: .macosFullscreenWindowsContainer)
        workspace.normalizeContainers()
        window2.isMacosFullscreenForTest = false
        try await normalizeLayoutReason()
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))

        // The command exits fullscreen before the native state is detected
        window2.bindToMacosNativeStateContainer(workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: 1)
        #expect(window2.bindBackToTilingSlot(on: workspace))
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
    }

    /// E.g. the app of windows 2, 3 and 4 is hidden. They come back one by one in any order
    @Test(arguments: [[2, 3, 4], [2, 4, 3], [3, 2, 4], [3, 4, 2], [4, 2, 3], [4, 3, 2]] as [[OpaqueWindowId]])
    func testThreeLevels(order: [OpaqueWindowId]) async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var windows: [OpaqueWindowId: TestWindow] = [:]
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 10, parent: $0)
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                windows[2] = TestWindow.new(id: 2, parent: $0)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    windows[3] = TestWindow.new(id: 3, parent: $0)
                    windows[4] = TestWindow.new(id: 4, parent: $0)
                }
            }
        }
        try await setFullscreen(Array(windows.values), true, workspace)
        for id in order {
            root.children.first?.markAsMostRecentChild() // A new window would split window 10
            try await setFullscreen([windows[id].orDie()], false, workspace)
        }
        assertEquals(root.layoutDescription, .h_tiles([
            .window(10),
            .window(1),
            .v_tiles([.window(2), .h_tiles([.window(3), .window(4)])]),
        ]))
    }

    /// Windows of the root leave, the root is left with a single container. They come back to the root, not into the
    /// container
    @Test(arguments: [false, true])
    func testRootLevelWindows(reversedExit: Bool) async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var windows: [TestWindow] = []
        let root = workspace.rootTilingContainer.apply {
            windows.append(TestWindow.new(id: 10, parent: $0))
            windows.append(TestWindow.new(id: 1, parent: $0))
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        for window in windows { try await setFullscreen([window], true, workspace) }
        for window in reversedExit ? windows : windows.reversed() { try await setFullscreen([window], false, workspace) }
        assertEquals(root.layoutDescription, .h_tiles([.window(10), .window(1), .v_tiles([.window(2), .window(3)])]))
    }

    /// The window is moved to another workspace while it's in native fullscreen. It doesn't go back to its old place
    @Test func testWindowMovedWhileAway() async throws {
        let workspace = Workspace.get(byName: "a")
        #expect(workspace.focusWorkspace())
        var window3: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
            window3 = TestWindow.new(id: 3, parent: $0)
        }
        try await setFullscreen([window3], true, workspace)
        await parseCommand("move-node-to-workspace other").cmdOrDie.run(.defaultEnv.withWindowId(window3.windowId), .emptyStdin)
        assertNil(window3.tilingSlot)
        await parseCommand("move-node-to-workspace a").cmdOrDie.run(.defaultEnv.withWindowId(window3.windowId), .emptyStdin)
        try await setFullscreen([window3], false, workspace)
        assertEquals(window3.nodeWorkspace, workspace)
        assertEquals(root.allLeafWindowsRecursive.count, 3)
    }

    /// Dwindle: window 3 split window 2 in half. Window 3 is closed while it's in native fullscreen itself
    @Test func testWindowClosedWhileAwayGivesTheWeightBack() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 420)
            TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1500) // 1500x1080 (wide)
        }
        let window3 = TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)
        window3.bindAsNewTilingWindow(to: workspace)
        try await setFullscreen([window3], true, workspace)
        window3.closeAxWindow()
        workspace.normalizeContainers()
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
        assertEquals(root.children.map { $0.getWeight(.h) }, [420, 1500])
    }

    /// The slot is gone: the window is placed as a new window
    @Test func testWindowOfAnotherWorkspaceIsPlacedAsNewWindow() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window2: TestWindow!
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            window2 = TestWindow.new(id: 2, parent: $0)
        }
        // E.g. minimized on this workspace, unminimized on another one
        window2.enterMacosNativeState(macosMinimizedWindowsContainer, prevParentKind: .tilingContainer, adaptiveWeight: 1)
        let other = Workspace.get(byName: "other")
        TestWindow.new(id: 3, parent: other.rootTilingContainer)
        try await exitMacOsNativeUnconventionalState(window: window2, prevParentKind: .tilingContainer, workspace: other, .nonCancellable)
        assertEquals(other.rootTilingContainer.layoutDescription, .h_tiles([.window(3), .window(2)]))
        assertNil(window2.tilingSlot)
    }
}
