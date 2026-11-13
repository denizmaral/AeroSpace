@testable import AppBundle
import Common
import Foundation
import Testing

/// A floating window that remembers its tile (`pop-out`, `layout floating`, see TilingSlot) still remembers it after a
/// restart of MarSpace: the persisted tree holds it at the place where it comes back to (an away window, see
/// TilingTreeSnapshot). Made a tile after the restart, it's where it would have been without the restart
@MainActor
@Suite(.serializedGlobally)
struct RememberedTileAcrossRestartTest {
    init() { setUpWorkspacesForTests() }

    private func nativeId(_ window: Window) -> UInt32? { UInt32(window.windowId.rawId) }

    private func run(_ command: String) async {
        await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
    }

    private func window(_ id: OpaqueWindowId) -> Window { Window.get(byId: id).orDie() }

    private func weights(_ node: TreeNode) -> [CGFloat] {
        guard let container = node as? TilingContainer else { return [] }
        return container.children.map { ($0.getWeight(container.orientation) * 1e9).rounded() / 1e9 } + container.children.flatMap(weights)
    }

    private func setUpWithNormalizations() -> Workspace {
        setUpWorkspacesForTests()
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        return Workspace.get(byName: name)
    }

    private func normalize() {
        for workspace in Workspace.all { workspace.normalizeContainers() }
    }

    /// What a restart of MarSpace does: the trees go through the file, the tiles are registered again in an arbitrary
    /// order as new tiles, and the floating windows float again with their flags (pinned, popped out), without their
    /// places in the trees. Then the trees are restored
    private func restart(_ workspaces: [Workspace]) throws {
        let trees = workspaces.compactMap { $0.tilingTreeSnapshot(windowId: nativeId) }
        let file = try #require(WindowPlacementSnapshot(data: WindowPlacementSnapshot.encode([], trees: trees, bootSession: 1)))
        assertEquals(file.trees, trees)
        for workspace in workspaces {
            for window in workspace.floatingWindowsIfAny { window.tilingSlot = nil }
            let tiles = workspace.rootTilingContainer.allLeafWindowsRecursive
            workspace.rootTilingContainer.unbindFromParent()
            for tile in tiles.reversed() {
                tile.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
            }
        }
        for tree in file.trees {
            Workspace.get(byName: tree.workspace).restoreTilingTree(tree, windowId: nativeId)
        }
        normalize()
    }

    /// Pops the windows out (`popOut`), and back in (`popIn`): directly, and with a restart of MarSpace in between. Both
    /// end the same
    private func assertSameWithRestart(
        _ build: (TilingContainer) -> Void,
        popOut: [OpaqueWindowId],
        popIn: [OpaqueWindowId],
        sourceLocation: SourceLocation = #_sourceLocation,
    ) async throws {
        var results: [(LayoutDescription, [CGFloat])] = []
        for withRestart in [false, true] {
            let workspace = setUpWithNormalizations()
            build(workspace.rootTilingContainer)
            normalize()
            let before = workspace.rootTilingContainer.layoutDescription
            for id in popOut {
                #expect(window(id).focusWindow(), sourceLocation: sourceLocation)
                await run("pop-out")
                normalize()
            }
            if withRestart {
                try restart([workspace])
                for id in popOut {
                    #expect(window(id).tilingSlot != nil, "\(id) remembers its tile", sourceLocation: sourceLocation)
                    #expect(window(id).isPoppedOut, "\(id) is popped out", sourceLocation: sourceLocation)
                }
            }
            for id in popIn {
                #expect(window(id).focusWindow(), sourceLocation: sourceLocation)
                await run("pop-out")
                normalize()
            }
            results.append((workspace.rootTilingContainer.layoutDescription, weights(workspace.rootTilingContainer)))
            if !withRestart { assertEquals(results[0].0, before, sourceLocation: sourceLocation) } // Back where they were
        }
        assertEquals(results[1].0, results[0].0, sourceLocation: sourceLocation)
        assertEquals(results[1].1, results[0].1, sourceLocation: sourceLocation)
    }

    @Test func testAWindowOfTheRoot() async throws {
        let pair: (TilingContainer) -> Void = { root in
            TestWindow.new(id: 1, parent: root, adaptiveWeight: 1)
            TestWindow.new(id: 2, parent: root, adaptiveWeight: 3)
        }
        try await assertSameWithRestart(pair, popOut: [2], popIn: [2])
        try await assertSameWithRestart(pair, popOut: [1], popIn: [1])
    }

    /// Dwindle placement makes nested pairs: the normalization flattens the pair when one of its windows pops out, the
    /// window splits its neighbor again when it pops back in
    @Test func testAWindowOfANestedPair() async throws {
        let tree: (TilingContainer) -> Void = { root in
            TestWindow.new(id: 1, parent: root, adaptiveWeight: 1)
            TilingContainer.newVTiles(parent: root, adaptiveWeight: 2).apply {
                TestWindow.new(id: 2, parent: $0, adaptiveWeight: 3)
                TestWindow.new(id: 3, parent: $0, adaptiveWeight: 1)
            }
        }
        try await assertSameWithRestart(tree, popOut: [2], popIn: [2]) // Before its neighbor
        try await assertSameWithRestart(tree, popOut: [3], popIn: [3]) // After it
        // The root is left with the pair: it takes the orientation of the pair, and is wrapped again
        try await assertSameWithRestart(tree, popOut: [1], popIn: [1])
    }

    @Test func testTheNeighborIsAContainer() async throws {
        let tree: (TilingContainer) -> Void = { root in
            TestWindow.new(id: 1, parent: root, adaptiveWeight: 1)
            TilingContainer.newVTiles(parent: root, adaptiveWeight: 2).apply {
                TestWindow.new(id: 2, parent: $0, adaptiveWeight: 1)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 2).apply {
                    TestWindow.new(id: 3, parent: $0, adaptiveWeight: 1)
                    TestWindow.new(id: 4, parent: $0, adaptiveWeight: 3)
                }
            }
        }
        try await assertSameWithRestart(tree, popOut: [4], popIn: [4])
        try await assertSameWithRestart(tree, popOut: [2], popIn: [2])
    }

    @Test func testTwoWindowsOfTheSameContainer() async throws {
        let tree: (TilingContainer) -> Void = { root in
            TestWindow.new(id: 1, parent: root, adaptiveWeight: 1)
            TestWindow.new(id: 2, parent: root, adaptiveWeight: 2)
            TestWindow.new(id: 3, parent: root, adaptiveWeight: 3)
        }
        try await assertSameWithRestart(tree, popOut: [2, 3], popIn: [2, 3])
        try await assertSameWithRestart(tree, popOut: [2, 3], popIn: [3, 2])
    }

    @Test func testAColumnOfAScrollingWorkspace() async throws {
        let workspace = setUpWithNormalizations()
        for id: OpaqueWindowId in [1, 2, 3] {
            TestWindow.new(id: id, parent: workspace.rootTilingContainer)
        }
        #expect(window(2).focusWindow())
        await run("workspace-layout scrolling")
        let columns = workspace.rootTilingContainer.layoutDescription
        await run("pop-out")
        try restart([workspace])
        #expect(window(2).tilingSlot != nil)
        await run("pop-out")
        normalize()
        assertEquals(workspace.rootTilingContainer.layoutDescription, columns)
    }

    /// `layout floating` and back: the window goes back to its tile after a restart too
    @Test func testLayoutFloating() async throws {
        let workspace = setUpWithNormalizations()
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TilingContainer.newVTiles(parent: workspace.rootTilingContainer, adaptiveWeight: 1).apply {
            TestWindow.new(id: 2, parent: $0)
            TestWindow.new(id: 3, parent: $0)
        }
        let tiles = workspace.rootTilingContainer.layoutDescription
        #expect(window(2).focusWindow())
        await run("layout floating")
        normalize()
        try restart([workspace])
        assertEquals(window(2).isFloating, true)
        await run("layout tiling")
        normalize()
        assertEquals(workspace.rootTilingContainer.layoutDescription, tiles)
    }

    /// Popped out, it came along to another workspace: it stays there after the restart, and remembers its tile
    @Test func testItCameAlongToAnotherWorkspace() async throws {
        _ = setUpWithNormalizations()
        let first = Workspace.get(byName: "A") // The name of the test isn't a command line argument
        TestWindow.new(id: 1, parent: first.rootTilingContainer)
        TestWindow.new(id: 2, parent: first.rootTilingContainer)
        let tiles = first.rootTilingContainer.layoutDescription
        #expect(window(1).focusWindow())
        await run("pop-out")
        await run("workspace B")
        Workspace.movePinnedWindowsToVisibleWorkspaces()
        let second = Workspace.get(byName: "B")

        try restart([first, second])
        assertEquals(window(1).nodeWorkspace, second)
        assertEquals(window(1).isPoppedOut, true)
        #expect(window(1).tilingSlot != nil)

        await run("workspace A")
        Workspace.movePinnedWindowsToVisibleWorkspaces()
        #expect(window(1).focusWindow())
        await run("pop-out")
        normalize()
        assertEquals(first.rootTilingContainer.layoutDescription, tiles)
    }

    /// The places of the floating windows aren't windows of the layout: no tiles, no tree
    @Test func testOnlyFloatingWindowsNoSnapshot() async {
        let workspace = setUpWithNormalizations()
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        #expect(window(1).focusWindow())
        await run("pop-out")
        #expect(workspace.tilingTreeSnapshot(windowId: nativeId) == nil)
    }
}
