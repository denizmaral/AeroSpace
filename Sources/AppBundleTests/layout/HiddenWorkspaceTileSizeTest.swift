@testable import AppBundle
import Common
import CoreGraphics
import Testing

/// The windows of a workspace that isn't shown wait in a corner of the screen with the sizes of their tiles: showing the
/// workspace only moves them. After a restart of MarSpace they had the sizes that the previous run gave them when it quit
@MainActor
@Suite(.serializedGlobally)
struct HiddenWorkspaceTileSizeTest {
    init() { setUpWorkspacesForTests() }

    @Test func testTileSizesAreTheTilesOfTheShownWorkspace() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(!workspace.isVisible)
        var windows: [TestWindow] = []
        workspace.rootTilingContainer.apply {
            windows.append(TestWindow.new(id: 1, parent: $0, adaptiveWeight: 2))
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1, index: INDEX_BIND_LAST).apply {
                windows.append(TestWindow.new(id: 2, parent: $0))
                windows.append(TestWindow.new(id: 3, parent: $0))
            }
        }

        let tiles = workspace.tileSizesWhileHidden()
        assertEquals(windows.map(\.sentFrames.count), [0, 0, 0])

        try await workspace.layoutWorkspace()
        assertEquals(windows.map { tiles[$0] }, windows.map { $0.lastAppliedLayoutPhysicalRect?.size })
        assertEquals(tiles[windows[0]], CGSize(width: 1280, height: 1079))
    }

    /// No window is asked for another size than its tile, also App Store that covers a part of the next one
    @Test func testWindowThatRefusesItsTileGetsItsTile() {
        let workspace = Workspace.get(byName: name)
        let appStore = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        appStore.minimumSizeForTest = CGSize(width: 1000, height: 0)
        let gitHub = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)

        let tiles = workspace.tileSizesWhileHidden()
        assertEquals(tiles[appStore], CGSize(width: 960, height: 1079))
        assertEquals(tiles[gitHub], CGSize(width: 960, height: 1079))
    }

    @Test func testFullscreenWindowGetsTheMonitor() {
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let fullscreen = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        fullscreen.markAsMostRecentChild()
        fullscreen.isFullscreen = true

        let tiles = workspace.tileSizesWhileHidden()
        assertEquals(tiles[fullscreen], workspace.workspaceMonitorInfo.visibleRectPaddedByOuterGaps.size)
        assertEquals(fullscreen.sentFrames.count, 0)
    }

    /// A window on another macOS Space refuses frames: it isn't sent any
    @Test func testWindowThatIsNotThereGetsNoSize() {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let invisible = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        invisible.lifeStatus = .invisible

        let tiles = workspace.tileSizesWhileHidden()
        assertEquals(tiles[window], workspace.rootTilingRect.size)
        assertEquals(tiles[invisible], nil)
    }
}
