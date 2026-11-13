@testable import AppBundle
import Common
import Foundation
import Testing

/// After a restart of MarSpace, the windows go back to their places in the layout, with their sizes
@MainActor
@Suite(.serializedGlobally)
struct TilingTreeSnapshotTest {
    init() { setUpWorkspacesForTests() }

    private func nativeId(_ window: Window) -> UInt32? { UInt32(window.windowId.rawId) }

    /// h[1, v[2, h[3, 4]]], window 1 a third of the width
    @discardableResult
    private func makeTree(_ workspace: Workspace) -> TilingContainer {
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0, adaptiveWeight: 1)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 2).apply {
                TestWindow.new(id: 2, parent: $0, adaptiveWeight: 3)
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 3, parent: $0, adaptiveWeight: 1)
                    TestWindow.new(id: 4, parent: $0, adaptiveWeight: 1)
                }
            }
        }
    }

    /// What a restart does: every window is registered again, in an arbitrary order, as a new window
    private func scramble(_ workspace: Workspace, order: [Window]) {
        workspace.rootTilingContainer.unbindFromParent()
        for window in order {
            window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
    }

    private func weights(_ node: TreeNode) -> [CGFloat] {
        guard let container = node as? TilingContainer else { return [] }
        return container.children.map { $0.getWeight(container.orientation) } + container.children.flatMap(weights)
    }

    @Test func testWindowsReturnToTheirPlacesAndSizes() throws {
        let workspace = Workspace.get(byName: name)
        let original = makeTree(workspace)
        let windows = original.allLeafWindowsRecursive
        #expect(windows[1].focusWindow()) // Window 2 is the most recent one
        let snapshot = try #require(workspace.tilingTreeSnapshot(windowId: nativeId))
        let expected = original.layoutDescription
        let expectedWeights = weights(original)

        scramble(workspace, order: [windows[3], windows[0], windows[2], windows[1]])
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(4), .window(1), .window(3), .window(2)]))
        #expect(windows[3].focusWindow())

        workspace.restoreTilingTree(snapshot, windowId: nativeId)
        assertEquals(workspace.rootTilingContainer.layoutDescription, expected)
        assertEquals(weights(workspace.rootTilingContainer), expectedWeights)
        assertEquals(workspace.rootTilingContainer.mostRecentWindowRecursive?.windowId, 2)
    }

    @Test func testOrientationAndLayoutOfTheRoot() throws {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TestWindow.new(id: 2, parent: $0)
        }
        root.changeOrientation(.v)
        root.layout = .accordion
        let snapshot = try #require(workspace.tilingTreeSnapshot(windowId: nativeId))

        scramble(workspace, order: root.allLeafWindowsRecursive.reversed())
        workspace.restoreTilingTree(snapshot, windowId: nativeId)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .v_accordion([.window(1), .window(2)]))
    }

    /// A window was closed while MarSpace wasn't running, and another one was opened
    @Test func testClosedAndNewWindows() throws {
        config.enableNormalizationFlattenContainers = true
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let workspace = Workspace.get(byName: name)
        let windows = makeTree(workspace).allLeafWindowsRecursive
        #expect(windows[1].focusWindow()) // Window 2 is the most recent one
        let snapshot = try #require(workspace.tilingTreeSnapshot(windowId: nativeId))

        windows[3].unbindFromParent() // Window 4 is gone
        scramble(workspace, order: [windows[2], windows[1], windows[0]])
        TestWindow.new(id: 5, parent: workspace.rootTilingContainer)

        workspace.restoreTilingTree(snapshot, windowId: nativeId)
        workspace.normalizeContainers()
        // The container of 3 and 4 is flattened, the new window is placed like a new window: after the most recent one
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2), .window(5), .window(3)])]))
    }

    /// A window rule floated the window or moved it to another workspace when it was detected again: it stays there
    @Test func testWindowsThatAreElsewhereStayThere() throws {
        let workspace = Workspace.get(byName: name)
        let other = Workspace.get(byName: "other")
        let windows = makeTree(workspace).allLeafWindowsRecursive
        let snapshot = try #require(workspace.tilingTreeSnapshot(windowId: nativeId))

        scramble(workspace, order: [windows[1], windows[0]])
        windows[2].bindAsFloatingWindow(to: workspace)
        windows[3].bind(to: other.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)

        workspace.restoreTilingTree(snapshot, windowId: nativeId)
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1), .v_tiles([.window(2)])]))
        assertEquals(workspace.floatingWindows.map(\.windowId), [3])
        assertEquals(other.rootTilingContainer.layoutDescription, .h_tiles([.window(4)]))
    }

    /// None of the windows of the snapshot is there: the tree stays as it is
    @Test func testNothingToRestore() throws {
        let workspace = Workspace.get(byName: name)
        makeTree(workspace)
        let snapshot = try #require(workspace.tilingTreeSnapshot(windowId: nativeId))
        scramble(workspace, order: [])
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 7, parent: $0)
            TestWindow.new(id: 8, parent: $0)
        }

        workspace.restoreTilingTree(snapshot, windowId: nativeId)
        #expect(workspace.rootTilingContainer === root)
        assertEquals(root.layoutDescription, .h_tiles([.window(7), .window(8)]))
    }

    @Test func testNoTilingWindowsNoSnapshot() {
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer)
        assertNil(workspace.tilingTreeSnapshot(windowId: nativeId))
    }

    @Test func testFileRoundTrip() throws {
        let workspace = Workspace.get(byName: name)
        makeTree(workspace)
        let trees = [
            try #require(workspace.tilingTreeSnapshot(windowId: nativeId)),
            PersistedTilingTree(
                workspace: "Übersicht 📋",
                mostRecentWindow: nil,
                root: .init(orientation: .v, layout: .accordion, weight: 1, children: [.window(id: 0xFFFF_FFFF, weight: 0.25)]),
            ),
        ]
        let placements = [WindowPlacement(nativeWindowId: 7, pid: 100, workspace: "1", isFloating: false)]
        let snapshot = try #require(WindowPlacementSnapshot(data: WindowPlacementSnapshot.encode(placements, trees: trees, bootSession: 1)))
        assertEquals(snapshot.trees, trees)
        assertEquals(snapshot.all, placements)
        assertEquals(snapshot.placement(nativeWindowId: 7, pid: 100), placements[0])
    }

    /// The file of the MarSpace version before the trees is still read when MarSpace is updated: the windows go back to
    /// their workspaces
    @Test func testFileWithoutTrees() throws {
        let placements = [WindowPlacement(nativeWindowId: 7, pid: 100, workspace: "T", isFloating: true)]
        var version2 = WindowPlacementSnapshot.encode(placements, bootSession: 1)
        version2[4] = 2
        version2.removeSubrange(24 ..< 28) // The length of the trees
        let snapshot = try #require(WindowPlacementSnapshot(data: version2))
        assertEquals(snapshot.all, placements)
        assertEquals(snapshot.trees, [])
    }

    /// Damaged trees restore nothing, and never crash
    @Test func testDamagedTrees() throws {
        let workspace = Workspace.get(byName: name)
        makeTree(workspace)
        let encoded = [try #require(workspace.tilingTreeSnapshot(windowId: nativeId))].encoded()
        assertEquals([PersistedTilingTree](decoding: encoded)?.count, 1)
        for length in 0 ..< encoded.count {
            #expect([PersistedTilingTree](decoding: encoded.prefix(length)) == nil)
        }
        #expect([PersistedTilingTree](decoding: encoded + [0]) == nil)
        for index in encoded.indices { // Any byte changed: decoded or refused
            var damaged = encoded
            damaged[index] ^= 0xFF
            _ = [PersistedTilingTree](decoding: damaged)
        }
        // Containers nested deeper than any real tree
        var deep = Data([1, 0, 1, 0, 65, 0, 0, 0, 0]) // One workspace "A", no most recent window
        for _ in 0 ..< 10000 { deep.append(contentsOf: [0, 0] + [0, 0, 0, 0, 0, 0, 0xF0, 0x3F] + [1, 0] + [1]) }
        #expect([PersistedTilingTree](decoding: deep) == nil)
    }
}
