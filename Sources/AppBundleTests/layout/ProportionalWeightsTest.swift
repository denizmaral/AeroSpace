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
    /// not their old weights (500 next to 1 would leave no space for the new window)
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
        assertEquals(widths(workspace), [960, 960]) // It was alone when it left: an equal share
        try await setFullscreen([windows[1]], false, workspace)
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2), .window(3)]))
        // Its old share (900 next to 500), the others share the rest
        assertEquals(widths(workspace), [343, 1234, 343])
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
}
