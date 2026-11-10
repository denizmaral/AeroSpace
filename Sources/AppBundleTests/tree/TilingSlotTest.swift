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

    /// The normalization flattens the container of the window. The window splits its neighbor again
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
            assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))
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

    /// E.g. Zen Browser next to two terminals. The root takes the children and the orientation of the flattened container
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
            assertEquals(root.layoutDescription, .v_tiles([.window(2), .window(3)]))
        }
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(3)])]))
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
