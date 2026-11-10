@testable import AppBundle
import Common
import CoreGraphics
import Testing

/// "No gaps around a single window" (Hyprland's smart gaps): the only tiling window of a workspace fills the screen
@MainActor
@Suite(.serializedGlobally)
struct SmartGapsTest {
    init() {
        setUpWorkspacesForTests()
        config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .init(left: 20, bottom: 20, top: 20, right: 20))
    }

    private let whole = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1079)
    private let padded = Rect(topLeftX: 20, topLeftY: 20, width: 1880, height: 1039)

    private func frame(_ window: TestWindow) -> Rect? {
        window.sentFrames.last.flatMap { frame in
            frame.topLeft.flatMap { origin in frame.size.map { Rect(topLeftX: origin.x, topLeftY: origin.y, width: $0.width, height: $0.height) } }
        }
    }

    @Test func testASingleWindowFillsTheScreen() async throws {
        config.smartGaps = true
        let workspace = Workspace.get(byName: name)
        let window1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        assertEquals(frame(window1), whole)

        // A second window: the gaps are back, around and between them
        let window2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        assertEquals(frame(window1), Rect(topLeftX: 20, topLeftY: 20, width: 935, height: 1039))
        assertEquals(frame(window2), Rect(topLeftX: 965, topLeftY: 20, width: 935, height: 1039))

        // A window on another macOS Space isn't there, a floating window doesn't tile
        window2.lifeStatus = .invisible
        TestWindow.new(id: 3, parent: workspace.floatingWindowsContainer)
        try await workspace.layoutWorkspace()
        assertEquals(frame(window1), whole)
    }

    @Test func testASingleWindowInANestedContainer() async throws {
        config.smartGaps = true
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: TilingContainer.newVTiles(parent: workspace.rootTilingContainer, adaptiveWeight: 1))
        try await workspace.layoutWorkspace()
        assertEquals(frame(window), whole)
    }

    @Test func testOffByDefault() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        assertEquals(frame(window), padded)
    }

    @Test func testTheSettingCompiles() {
        var settings = Settings()
        assertEquals(settings.compile().config.smartGaps, false)
        settings.appearance.gaps.noneAroundSingleWindow = true
        assertEquals(settings.compile().config.smartGaps, true)
    }
}
