@testable import AppBundle
import Common
import CoreGraphics
import Testing

/// The layout runs at the end of every refresh session. Unchanged frames must not be sent to the windows again,
/// every send is several accessibility round trips to the app. See Window.setAxFrame
@MainActor
@Suite(.serializedGlobally)
struct LayoutFrameCacheTest {
    init() { setUpWorkspacesForTests() }

    @Test func testUnchangedLayoutSendsNothing() async throws {
        let workspace = Workspace.get(byName: name)
        var windows: [TestWindow] = []
        workspace.rootTilingContainer.apply {
            windows.append(TestWindow.new(id: 1, parent: $0))
            windows.append(TestWindow.new(id: 2, parent: $0))
        }

        try await workspace.layoutWorkspace()
        assertEquals(windows.map(\.sentFrames.count), [1, 1])
        assertEquals(windows[0].sentFrames.first?.size, CGSize(width: 960, height: 1079))

        try await workspace.layoutWorkspace()
        try await workspace.layoutWorkspace()
        assertEquals(windows.map(\.sentFrames.count), [1, 1])
    }

    @Test func testInvalidatedWindowIsSentAgain() async throws {
        let workspace = Workspace.get(byName: name)
        var windows: [TestWindow] = []
        workspace.rootTilingContainer.apply {
            windows.append(TestWindow.new(id: 1, parent: $0))
            windows.append(TestWindow.new(id: 2, parent: $0))
        }
        try await workspace.layoutWorkspace()

        // E.g. the user moved the window with the mouse: kAXMovedNotification
        windows[1].invalidateSentFrame()
        try await workspace.layoutWorkspace()
        assertEquals(windows.map(\.sentFrames.count), [1, 2])
    }

    @Test func testOnlyWindowsWithChangedFramesAreSent() async throws {
        let workspace = Workspace.get(byName: name)
        var windows: [TestWindow] = []
        let root = workspace.rootTilingContainer.apply {
            windows.append(TestWindow.new(id: 1, parent: $0))
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1, index: INDEX_BIND_LAST).apply {
                windows.append(TestWindow.new(id: 2, parent: $0))
                windows.append(TestWindow.new(id: 3, parent: $0))
            }
        }
        try await workspace.layoutWorkspace()
        assertEquals(windows.map(\.sentFrames.count), [1, 1, 1])

        // Only the windows in the right column change
        let column = try #require(root.children.last as? TilingContainer)
        windows[1].setWeight(.v, column.getWeight(.v) * 0.75)
        windows[2].setWeight(.v, column.getWeight(.v) * 0.25)
        try await workspace.layoutWorkspace()
        assertEquals(windows.map(\.sentFrames.count), [1, 2, 2])
    }
}
