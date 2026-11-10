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

    /// The focus border surrounds the frame that the window really has: App Store refuses to shrink to its tile
    @Test func testAppliedFrameIsReadOncePerFrameChange() async throws {
        let workspace = Workspace.get(byName: name)
        let appStore = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        appStore.axRectForTest = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1079)

        assertEquals(try await appStore.getAppliedFrame(.cancellable)?.width, 1920)
        try await workspace.layoutWorkspace() // Nothing is sent
        assertEquals(try await appStore.getAppliedFrame(.cancellable)?.width, 1920)
        assertEquals(appStore.axRectReadCount, 1)

        // A new window takes the right half, App Store refuses to shrink to the left half
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        appStore.axRectForTest = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 1079)
        assertEquals(try await appStore.getAppliedFrame(.cancellable)?.width, 1000)
        assertEquals(appStore.axRectReadCount, 2)

        // E.g. the app resized its window itself: kAXResizedNotification
        appStore.invalidateSentFrame()
        appStore.axRectForTest = Rect(topLeftX: 0, topLeftY: 0, width: 1100, height: 1079)
        assertEquals(try await appStore.getAppliedFrame(.cancellable)?.width, 1100)
        assertEquals(appStore.axRectReadCount, 3)
    }

    /// A frame sent while the frame is read: the read may be from before it
    @Test func testAppliedFrameReadDuringASendIsNotKept() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        window.axRectForTest = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1079)

        window.onAxRectReadForTest = { window.setAxFrame(CGPoint(x: 0, y: 0), CGSize(width: 960, height: 1079)) }
        assertEquals(try await window.getAppliedFrame(.cancellable)?.width, 1920)
        window.axRectForTest = Rect(topLeftX: 0, topLeftY: 0, width: 960, height: 1079) // The app applied the frame
        assertEquals(try await window.getAppliedFrame(.cancellable)?.width, 960)
        assertEquals(window.axRectReadCount, 2)
    }
}
