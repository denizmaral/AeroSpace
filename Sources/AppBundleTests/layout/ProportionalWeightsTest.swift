@testable import AppBundle
import Common
import CoreGraphics
import Testing

/// The weights of the children of a tiles container are proportions: the layout never changes them (see
/// TilingContainer.proportionalLengths). The test monitor is 1920x1080 (the layout height is 1079), no gaps
@MainActor
@Suite(.serializedGlobally)
struct ProportionalWeightsTest {
    init() {
        setUpWorkspacesForTests()
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        config.automaticallyUnhideMacosHiddenApps = true // The hidden app check needs MacApp
    }

    /// The same steps as on the device: the complete refresh session lays out right after normalizeLayoutReason, the
    /// next session normalizes the containers and lays out again
    private func setFullscreen(_ windows: [TestWindow], _ isFullscreen: Bool, _ workspace: Workspace) async throws {
        for window in windows { window.isMacosFullscreenForTest = isFullscreen }
        try await normalizeLayoutReason()
        try await workspace.layoutWorkspace()
        workspace.normalizeContainers()
        try await workspace.layoutWorkspace()
    }

    private func widths(_ workspace: Workspace) -> [CGFloat] {
        workspace.rootTilingContainer.allLeafWindowsRecursive.map { ($0.lastAppliedLayoutPhysicalRect?.width ?? -1).rounded() }
    }

    @Test func testLayoutDoesntChangeTheWeights() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
            TestWindow.new(id: 2, parent: $0, adaptiveWeight: 3)
        }
        try await workspace.layoutWorkspace()
        assertEquals(widths(workspace), [480, 1440])
        assertEquals(root.children.map { $0.getWeight(.h) }, [1, 3])
    }

    /// E.g. Zen Browser goes native fullscreen and comes back: exactly the same sizes as before, for every window
    @Test func testRoundTripIsExact() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var windows: [TestWindow] = []
        workspace.rootTilingContainer.apply {
            windows.append(TestWindow.new(id: 1, parent: $0, adaptiveWeight: 500))
            windows.append(TestWindow.new(id: 2, parent: $0, adaptiveWeight: 900))
            windows.append(TestWindow.new(id: 3, parent: $0, adaptiveWeight: 520))
        }
        try await workspace.layoutWorkspace()
        let before = widths(workspace)
        try await setFullscreen([windows[1]], true, workspace)
        try await setFullscreen([windows[1]], false, workspace)
        assertEquals(widths(workspace), before)
    }

    /// E.g. the app is hidden: two windows leave, they come back in any order, in one or several sessions
    @Test(arguments: [[0, 1], [1, 0], [0, 1, 2]])
    func testSeveralWindowsInAnyOrder(order: [Int]) async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var windows: [TestWindow] = []
        workspace.rootTilingContainer.apply {
            windows.append(TestWindow.new(id: 1, parent: $0, adaptiveWeight: 500))
            windows.append(TestWindow.new(id: 2, parent: $0, adaptiveWeight: 900))
            windows.append(TestWindow.new(id: 3, parent: $0, adaptiveWeight: 520))
        }
        try await workspace.layoutWorkspace()
        let before = widths(workspace)
        let away = [windows[1], windows[2]]
        try await setFullscreen([away[0]], true, workspace)
        try await setFullscreen([away[1]], true, workspace)
        if order.count == 3 {
            try await setFullscreen(away, false, workspace) // Together
        } else {
            for index in order { try await setFullscreen([away[index]], false, workspace) }
        }
        assertEquals(widths(workspace), before)
    }

    /// The container of the window is flattened while it's away: the window and its neighbor get their sizes back
    @Test func testFlattenedContainerIsExact() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window3: TestWindow!
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0, adaptiveWeight: 700)
                window3 = TestWindow.new(id: 3, parent: $0, adaptiveWeight: 379)
            }
        }
        try await workspace.layoutWorkspace()
        let rects = workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.lastAppliedLayoutPhysicalRect)
        try await setFullscreen([window3], true, workspace)
        try await setFullscreen([window3], false, workspace)
        assertEquals(workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.lastAppliedLayoutPhysicalRect), rects)
    }

    /// resize works in pixels, whatever the scale of the weights
    @Test func testResizeIsInPixels() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window1: TestWindow!
        workspace.rootTilingContainer.apply {
            window1 = TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
            TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1)
        }
        try await workspace.layoutWorkspace()
        assertEquals(window1.focusWindow(), true)
        await parseCommand("resize width +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertEquals(widths(workspace), [1060, 860])
        await parseCommand("resize width 800").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertEquals(widths(workspace), [800, 1120])
    }

    /// The user resizes a window while another one is away: the resize is kept, the window that comes back gets exactly
    /// its old size and the others share the rest in the proportions the user gave them
    @Test func testResizeWhileAwayIsKept() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var windows: [TestWindow] = []
        workspace.rootTilingContainer.apply {
            windows.append(TestWindow.new(id: 1, parent: $0, adaptiveWeight: 500))
            windows.append(TestWindow.new(id: 2, parent: $0, adaptiveWeight: 900))
            windows.append(TestWindow.new(id: 3, parent: $0, adaptiveWeight: 520))
        }
        try await workspace.layoutWorkspace()
        try await setFullscreen([windows[1]], true, workspace)
        let away = widths(workspace)
        assertEquals(windows[0].focusWindow(), true)
        await parseCommand("resize width +200").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertEquals(widths(workspace), [away[0] + 200, away[1] - 200])
        try await setFullscreen([windows[1]], false, workspace)
        let back = widths(workspace)
        assertEquals(back[1], 900) // Exactly its old size
        assertEquals((back[0] / back[2] * 100).rounded(), ((away[0] + 200) / (away[1] - 200) * 100).rounded()) // The user's proportions
    }

    /// A sibling is closed while the window is away: the window comes back to exactly its old size, the others take the
    /// share of the closed window
    @Test func testClosedWhileAwayGivesItsShare() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var windows: [TestWindow] = []
        workspace.rootTilingContainer.apply {
            windows.append(TestWindow.new(id: 1, parent: $0, adaptiveWeight: 500))
            windows.append(TestWindow.new(id: 2, parent: $0, adaptiveWeight: 900))
            windows.append(TestWindow.new(id: 3, parent: $0, adaptiveWeight: 520))
        }
        try await workspace.layoutWorkspace()
        try await setFullscreen([windows[1]], true, workspace)
        windows[2].closeAxWindow()
        try await setFullscreen([windows[1]], false, workspace)
        assertEquals(widths(workspace), [1020, 900])
    }

    /// A window is opened while another one is away: the window that comes back gets its old share, the new window takes
    /// its share from all
    @Test func testNewWindowWhileAway() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window2: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            _ = TestWindow.new(id: 1, parent: $0).focusWindow()
            window2 = TestWindow.new(id: 2, parent: $0)
        }
        try await workspace.layoutWorkspace()
        try await setFullscreen([window2], true, workspace)
        TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer).bindAsNewTilingWindow(to: workspace)
        try await workspace.layoutWorkspace()
        assertEquals(widths(workspace), [960, 960])
        try await setFullscreen([window2], false, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
        assertEquals(widths(workspace), [480, 960, 480])
    }

    /// All windows leave, a new window starts the weights from scratch: the windows that come back get their old shares,
    /// not their old weights (500 next to 1 would leave no space for the new window). Both were alone when they left
    /// (the other one was away already), so they get equal shares
    @Test func testAllAwayAndNewWindow() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var windows: [TestWindow] = []
        let root = workspace.rootTilingContainer.apply {
            windows.append(TestWindow.new(id: 1, parent: $0, adaptiveWeight: 500))
            windows.append(TestWindow.new(id: 2, parent: $0, adaptiveWeight: 900))
        }
        try await workspace.layoutWorkspace()
        try await setFullscreen([windows[0]], true, workspace)
        try await setFullscreen([windows[1]], true, workspace)
        TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer).bindAsNewTilingWindow(to: workspace)
        try await workspace.layoutWorkspace()
        assertEquals(root.children.map { $0.getWeight(.h) }, [1])
        try await setFullscreen([windows[0]], false, workspace)
        assertEquals(widths(workspace), [960, 960])
        try await setFullscreen([windows[1]], false, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
        assertEquals(widths(workspace), [640, 640, 640])
    }

    /// Two windows leave together, the third one is closed and a new window comes: the two come back to exactly their old
    /// sizes, the new window gets the rest
    @Test func testTwoAwayClosedAndNewWindow() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var windows: [TestWindow] = []
        let root = workspace.rootTilingContainer.apply {
            windows.append(TestWindow.new(id: 1, parent: $0, adaptiveWeight: 500))
            windows.append(TestWindow.new(id: 2, parent: $0, adaptiveWeight: 900))
            windows.append(TestWindow.new(id: 3, parent: $0, adaptiveWeight: 520))
        }
        try await workspace.layoutWorkspace()
        try await setFullscreen([windows[1], windows[2]], true, workspace)
        windows[0].closeAxWindow()
        TestWindow.new(id: 4, parent: workspace.floatingWindowsContainer).bindAsNewTilingWindow(to: workspace)
        try await workspace.layoutWorkspace()
        try await setFullscreen([windows[1]], false, workspace)
        try await setFullscreen([windows[2]], false, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(3), .window(4)]))
        // 2 and 3 had 900 + 520 of 1920 (1 is closed and frees its share for all), 4 takes the share of 1
        assertEquals(widths(workspace), [900, 520, 500])
    }

    /// Both windows of a container leave, the normalization removes the container. It comes back with its old share
    @Test func testEmptiedContainerComesBackWithItsShare() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window1: TestWindow!
        var away: [TestWindow] = []
        let root = workspace.rootTilingContainer.apply {
            window1 = TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 3).apply {
                away.append(TestWindow.new(id: 2, parent: $0))
                away.append(TestWindow.new(id: 3, parent: $0))
            }
        }
        try await workspace.layoutWorkspace()
        try await setFullscreen(away, true, workspace)
        _ = window1.focusWindow()
        TestWindow.new(id: 4, parent: workspace.floatingWindowsContainer).bindAsNewTilingWindow(to: workspace)
        try await workspace.layoutWorkspace()
        assertEquals(widths(workspace), [960, 960])
        try await setFullscreen(away, false, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)]), .window(4)]))
        assertEquals(widths(workspace), [240, 1440, 1440, 240])
    }

    /// The weights in the slots of away windows can have another scale than the weights in the tree: two windows (500,
    /// 500) leave, a new window starts from 1 and leaves too. They come back in any order with equal shares (500 next to 1
    /// gave the new window 4 px)
    @Test(arguments: [false, true])
    func testAwayWeightsOfAnotherScale(newWindowFirst: Bool) async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var windows: [TestWindow] = []
        let root = workspace.rootTilingContainer.apply {
            windows.append(TestWindow.new(id: 1, parent: $0, adaptiveWeight: 500))
            windows.append(TestWindow.new(id: 2, parent: $0, adaptiveWeight: 500))
        }
        try await workspace.layoutWorkspace()
        try await setFullscreen([windows[0]], true, workspace)
        try await setFullscreen([windows[1]], true, workspace)
        let window3 = TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)
        window3.bindAsNewTilingWindow(to: workspace)
        try await workspace.layoutWorkspace()
        try await setFullscreen([window3], true, workspace)
        for window in newWindowFirst ? [window3, windows[0]] : [windows[0], window3] {
            try await setFullscreen([window], false, workspace)
        }
        assertEquals(widths(workspace), [960, 960])
        try await setFullscreen([windows[1]], false, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
        assertEquals(widths(workspace), [640, 640, 640])
    }

    /// Dwindle: 3 split 2, all windows leave, a new window starts from 1, 2 comes back and 3 is closed while away: 2 takes
    /// the share of 3 in the scale of the tree now (the old weight of 3 gave the new window 3 px)
    @Test func testDwindleSplitClosedWhileAwayOtherScale() async throws {
        config.newWindowPlacement = .dwindle
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window1: TestWindow!
        var window2: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            window1 = TestWindow.new(id: 1, parent: $0, adaptiveWeight: 420)
            window2 = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1500)
        }
        _ = window2.focusWindow()
        let window3 = TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)
        window3.bindAsNewTilingWindow(to: workspace)
        assertEquals(root.children.map { $0.getWeight(.h) }, [420, 750, 750])
        try await workspace.layoutWorkspace()
        for window in [window3, window1!, window2!] { try await setFullscreen([window], true, workspace) }
        TestWindow.new(id: 4, parent: workspace.floatingWindowsContainer).bindAsNewTilingWindow(to: workspace)
        try await workspace.layoutWorkspace()
        try await setFullscreen([window2], false, workspace)
        assertEquals(widths(workspace), [960, 960])
        window3.closeAxWindow()
        workspace.normalizeContainers()
        try await workspace.layoutWorkspace()
        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(4)]))
        assertEquals(widths(workspace), [1440, 480]) // 3 was as big as 2 (750 next to 750), 2 has both shares
    }

    /// The container was created in the same session (it wasn't laid out yet): resize converts the pixels with the
    /// estimated length of the container
    @Test func testResizeInContainerNotLaidOutYet() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window1: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            window1 = TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        try await workspace.layoutWorkspace()
        _ = window1.focusWindow()
        await parseCommand("join-with right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await parseCommand("resize height +100").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertEquals(root.layoutDescription, .h_tiles([.v_tiles([.window(1), .window(2)]), .window(3)]))
        let heights = root.allLeafWindowsRecursive.prefix(2).map { (($0.lastAppliedLayoutPhysicalRect?.height ?? -1) * 2).rounded() / 2 }
        assertEquals(heights, [639.5, 439.5]) // 1079 / 2 + 100, 1079 / 2 - 100
    }

    /// A workspace that was never laid out (not visible): resize converts the pixels with the estimated length
    @Test func testResizeOnInvisibleWorkspace() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window1: TestWindow!
        var window2: TestWindow!
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 3, parent: $0)
            window1 = TestWindow.new(id: 1, parent: $0)
            window2 = TestWindow.new(id: 2, parent: $0)
        }
        try await workspace.layoutWorkspace()
        for window in [window1!, window2!] {
            await parseCommand("move-node-to-workspace hidden5").cmdOrDie.run(.defaultEnv.withWindowId(window.windowId), .emptyStdin)
        }
        await parseCommand("resize width +100").cmdOrDie.run(.defaultEnv.withWindowId(window1.windowId), .emptyStdin)
        let invisible = Workspace.get(byName: "hidden5")
        #expect(invisible.focusWorkspace())
        try await invisible.layoutWorkspace()
        assertEquals(widths(invisible), [1060, 860])
    }

    /// Both windows of a container leave, the normalization flattens the container. They come back in any order to
    /// exactly their old sizes
    @Test(arguments: [false, true])
    func testNeighborStillAwayUnequal(reversedReturn: Bool) async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window2: TestWindow!
        var window3: TestWindow!
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                window2 = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 700)
                window3 = TestWindow.new(id: 3, parent: $0, adaptiveWeight: 379)
            }
        }
        try await workspace.layoutWorkspace()
        let rects = workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.lastAppliedLayoutPhysicalRect)
        try await setFullscreen([window3], true, workspace)
        try await setFullscreen([window2], true, workspace)
        for window in reversedReturn ? [window2!, window3!] : [window3!, window2!] {
            try await setFullscreen([window], false, workspace)
        }
        assertEquals(workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.lastAppliedLayoutPhysicalRect), rects)
    }

    /// In whole pixels: the weights that come back are computed (old share times the length), the last bits may differ
    private func rects(_ workspace: Workspace) -> [[CGFloat]] {
        workspace.rootTilingContainer.allLeafWindowsRecursive.map { window in
            window.lastAppliedLayoutPhysicalRect.map { [$0.topLeftX, $0.topLeftY, $0.width, $0.height].map { $0.rounded() } } ?? []
        }
    }

    /// 5 leaves, 3 leaves (its container is flattened), 3 comes back (its container is created again), 5 comes back: 5
    /// finds its left sibling in the new container
    @Test func testOrderAfterContainerIsReplaced() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window3: TestWindow!
        var window5: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                window3 = TestWindow.new(id: 3, parent: $0)
                TestWindow.new(id: 4, parent: $0)
            }
            window5 = TestWindow.new(id: 5, parent: $0)
        }
        try await workspace.layoutWorkspace()
        let before = rects(workspace)
        try await setFullscreen([window5], true, workspace)
        try await setFullscreen([window3], true, workspace)
        try await setFullscreen([window3], false, workspace)
        try await setFullscreen([window5], false, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .v_tiles([.window(3), .window(4)]), .window(5)]))
        assertEquals(rects(workspace), before)
    }

    /// 10 and 1 leave the root, the root takes the orientation of the flattened container. Whichever comes back first
    /// wraps the children of the container again
    @Test(arguments: [false, true])
    func testRootLevelWindowsComeBackInAnyOrder(reversedReturn: Bool) async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var windows: [TestWindow] = []
        let root = workspace.rootTilingContainer.apply {
            windows.append(TestWindow.new(id: 10, parent: $0, adaptiveWeight: 300))
            windows.append(TestWindow.new(id: 1, parent: $0, adaptiveWeight: 600))
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1020).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        try await workspace.layoutWorkspace()
        let before = rects(workspace)
        for window in windows { try await setFullscreen([window], true, workspace) }
        for window in reversedReturn ? windows.reversed() : windows { try await setFullscreen([window], false, workspace) }
        assertEquals(root.layoutDescription, .h_tiles([.window(10), .window(1), .v_tiles([.window(2), .window(3)])]))
        assertEquals(rects(workspace), before)
    }

    /// Two of three windows of a container leave, the normalization flattens it. Whichever comes back first creates the
    /// container again next to the window that stayed, the other one comes back to it
    @Test(arguments: [false, true])
    func testTwoOfThreeLeaveFlattenedContainer(reversedReturn: Bool) async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window2: TestWindow!
        var window3: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                window2 = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 300)
                window3 = TestWindow.new(id: 3, parent: $0, adaptiveWeight: 300)
                TestWindow.new(id: 4, parent: $0, adaptiveWeight: 479)
            }
        }
        try await workspace.layoutWorkspace()
        let before = rects(workspace)
        try await setFullscreen([window2], true, workspace)
        try await setFullscreen([window3], true, workspace)
        for window in reversedReturn ? [window3!, window2!] : [window2!, window3!] {
            try await setFullscreen([window], false, workspace)
        }
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3), .window(4)])]))
        assertEquals(rects(workspace), before)
    }

    /// Many round trips of pairs of windows (nested container, flattened and created again): the tree and the sizes stay
    /// exactly the same
    @Test func testManyRoundTripsDontDrift() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var windows: [TestWindow] = []
        let root = workspace.rootTilingContainer.apply {
            windows.append(TestWindow.new(id: 1, parent: $0, adaptiveWeight: 0.1))
            windows.append(TestWindow.new(id: 2, parent: $0, adaptiveWeight: 0.7))
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 0.3).apply {
                windows.append(TestWindow.new(id: 3, parent: $0, adaptiveWeight: 0.2))
                windows.append(TestWindow.new(id: 4, parent: $0, adaptiveWeight: 0.9))
            }
            windows.append(TestWindow.new(id: 5, parent: $0, adaptiveWeight: 0.33))
        }
        try await workspace.layoutWorkspace()
        let before = rects(workspace)
        let tree = root.layoutDescription
        for i in 0 ..< 40 {
            let first = windows[(i * 3) % windows.count]
            let second = windows[(i * 7 + 1) % windows.count]
            try await setFullscreen([first], true, workspace)
            if second !== first { try await setFullscreen([second], true, workspace) }
            try await setFullscreen([i % 2 == 0 ? first : second], false, workspace)
            try await setFullscreen([first, second], false, workspace)
            assertEquals(root.layoutDescription, tree)
            assertEquals(rects(workspace), before)
        }
    }

    /// 1 leaves (the root takes the orientation of v), then 2 leaves the new root and comes back first: it comes back into
    /// the root as it was when it left, then 1 wraps the children again
    @Test func testWindowThatLeftAfterTheRootFlattenComesBackFirst() async throws {
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
        try await workspace.layoutWorkspace()
        let before = rects(workspace)
        try await setFullscreen([window1], true, workspace)
        try await setFullscreen([window2], true, workspace)
        try await setFullscreen([window2], false, workspace)
        assertEquals(root.layoutDescription, .v_tiles([.window(2), .window(3)]))
        try await setFullscreen([window1], false, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))
        assertEquals(rects(workspace), before)
    }

    /// The user moves the left sibling of an away window into another sibling (a container): the window doesn't follow it
    @Test func testLeftSiblingMovedIntoAnotherSibling() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window1: TestWindow!
        var window2: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            window1 = TestWindow.new(id: 1, parent: $0)
            window2 = TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 4, parent: $0)
                TestWindow.new(id: 5, parent: $0)
            }
        }
        try await workspace.layoutWorkspace()
        try await setFullscreen([window2], true, workspace)
        #expect(window1.focusWindow())
        for _ in 0 ..< 2 {
            await parseCommand("move right").cmdOrDie.run(.defaultEnv, .emptyStdin)
            workspace.normalizeContainers()
        }
        try await setFullscreen([window2], false, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(3), .v_tiles([.window(4), .window(5), .window(1)])]))
    }

    /// The container on the left of an away window is flattened (a window closed), the user swaps what is left of it:
    /// the window comes back after the sibling that is still in order
    @Test func testFlattenedLeftSiblingSwapped() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window2: TestWindow!
        var window3: TestWindow!
        var window4: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                window2 = TestWindow.new(id: 2, parent: $0)
                window3 = TestWindow.new(id: 3, parent: $0)
            }
            window4 = TestWindow.new(id: 4, parent: $0)
        }
        try await workspace.layoutWorkspace()
        try await setFullscreen([window4], true, workspace)
        window3.closeAxWindow()
        workspace.normalizeContainers()
        #expect(window2.focusWindow())
        await parseCommand("swap left").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await setFullscreen([window4], false, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(1), .window(4)]))
    }

    /// 1 leaves (the root takes the orientation of v), the user changes the layout of the root back and forth, 2 leaves:
    /// 2 left after 1, it comes back into the root as it is, then 1 wraps the children again
    @Test func testRootLayoutChangedWhileAway() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window1: TestWindow!
        var window2: TestWindow!
        var window3: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            window1 = TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                window2 = TestWindow.new(id: 2, parent: $0)
                window3 = TestWindow.new(id: 3, parent: $0)
            }
        }
        try await workspace.layoutWorkspace()
        let before = rects(workspace)
        try await setFullscreen([window1], true, workspace)
        #expect(window3.focusWindow())
        await parseCommand("layout accordion").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await setFullscreen([window2], true, workspace)
        await parseCommand("layout tiles").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await setFullscreen([window2], false, workspace)
        assertEquals(root.layoutDescription, .v_tiles([.window(2), .window(3)]))
        try await setFullscreen([window1], false, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))
        assertEquals(rects(workspace), before)
    }

    /// The user moves a window of the container on the left of an away window past its right sibling: the window comes
    /// back after what is left of the container, still before its right sibling
    @Test func testReplacedLeftSiblingStaysBeforeTheRightSibling() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window2: TestWindow!
        var window4: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                window2 = TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
            window4 = TestWindow.new(id: 4, parent: $0)
            TestWindow.new(id: 5, parent: $0)
        }
        try await workspace.layoutWorkspace()
        try await setFullscreen([window4], true, workspace)
        #expect(window2.focusWindow())
        for _ in 0 ..< 2 {
            await parseCommand("move right").cmdOrDie.run(.defaultEnv, .emptyStdin)
            workspace.normalizeContainers()
        }
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(3), .window(5), .window(2)]))
        try await setFullscreen([window4], false, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(3), .window(4), .window(5), .window(2)]))
    }

    /// 1 leaves (the root takes the orientation of v), then 3 leaves the new root. 1 comes back first and wraps the
    /// children again: 3 comes back into the wrapper, between its old siblings
    @Test func testWindowThatLeftAfterTheRootFlattenComesBackIntoTheWrapper() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window1: TestWindow!
        var window3: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            window1 = TestWindow.new(id: 1, parent: $0, adaptiveWeight: 600)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1320).apply {
                TestWindow.new(id: 2, parent: $0, adaptiveWeight: 300)
                window3 = TestWindow.new(id: 3, parent: $0, adaptiveWeight: 400)
                TestWindow.new(id: 4, parent: $0, adaptiveWeight: 379)
            }
        }
        try await workspace.layoutWorkspace()
        let before = rects(workspace)
        try await setFullscreen([window1], true, workspace)
        try await setFullscreen([window3], true, workspace)
        try await setFullscreen([window1], false, workspace)
        try await setFullscreen([window3], false, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3), .window(4)])]))
        assertEquals(rects(workspace), before)
    }

    /// 2 leaves v, then 1 leaves the root (the root takes the children of v). In any order, 2 comes back with its old
    /// share next to its old siblings
    @Test(arguments: [false, true])
    func testWindowOfTheFlattenedContainerKeepsItsShare(reversedReturn: Bool) async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window1: TestWindow!
        var window2: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            window1 = TestWindow.new(id: 1, parent: $0, adaptiveWeight: 500)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1420).apply {
                window2 = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 200)
                TestWindow.new(id: 3, parent: $0, adaptiveWeight: 600)
                TestWindow.new(id: 4, parent: $0, adaptiveWeight: 279)
            }
        }
        try await workspace.layoutWorkspace()
        let before = rects(workspace)
        try await setFullscreen([window2], true, workspace)
        try await setFullscreen([window1], true, workspace)
        for window in reversedReturn ? [window2!, window1!] : [window1!, window2!] {
            try await setFullscreen([window], false, workspace)
        }
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3), .window(4)])]))
        assertEquals(rects(workspace), before)
    }

    /// The root is flattened twice in a row: 1 leaves (the root takes v), 2 leaves (the root takes h). Whichever comes
    /// back first, the tree and the sizes are restored when both are back
    @Test(arguments: [false, true])
    func testRootFlattenedTwice(reversedReturn: Bool) async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        var window1: TestWindow!
        var window2: TestWindow!
        let root = workspace.rootTilingContainer.apply {
            window1 = TestWindow.new(id: 1, parent: $0, adaptiveWeight: 700)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1220).apply {
                window2 = TestWindow.new(id: 2, parent: $0, adaptiveWeight: 400)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 679).apply {
                    TestWindow.new(id: 3, parent: $0, adaptiveWeight: 500)
                    TestWindow.new(id: 4, parent: $0, adaptiveWeight: 720)
                }
            }
        }
        try await workspace.layoutWorkspace()
        let before = rects(workspace)
        try await setFullscreen([window1], true, workspace)
        try await setFullscreen([window2], true, workspace)
        for window in reversedReturn ? [window2!, window1!] : [window1!, window2!] {
            try await setFullscreen([window], false, workspace)
        }
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .h_tiles([.window(3), .window(4)])])]))
        assertEquals(rects(workspace), before)
    }
}
