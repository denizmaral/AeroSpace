@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct NormalizeLayoutReasonTest {
    init() { setUpWorkspacesForTests() }

    @Test func testNativeStateOfInvisibleWorkspaceIsCheckedWhenItBecomesVisible() async throws {
        let workspace = Workspace.get(byName: "invisible")
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        window.isMacosFullscreenForTest = true
        #expect(!workspace.isVisible)

        // No AX calls for windows of invisible workspaces
        try await normalizeLayoutReason()
        assertEquals(window.layoutReason, .standard)

        #expect(workspace.focusWorkspace())
        try await normalizeLayoutReason()
        assertEquals(window.layoutReason, .macos(prevParentKind: .tilingContainer))
        #expect(window.parent === workspace.macOsNativeFullscreenWindowsContainer)
    }
}

@MainActor
@Suite(.serializedGlobally)
struct NormalizeLayoutReasonOfNewlyVisibleWorkspacesTest {
    init() { setUpWorkspacesForTests() }

    /// E.g. the `workspace` command lays out the workspace before the next complete refresh session
    @Test func testNewlyVisibleWorkspaceIsCheckedBeforeLayout() async throws {
        config.automaticallyUnhideMacosHiddenApps = true // The hidden app check needs MacApp
        let workspace = Workspace.get(byName: "invisible")
        let fullscreen = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        fullscreen.isMacosFullscreenForTest = true
        let window = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await normalizeLayoutReason() // A complete refresh session while the workspace is invisible

        #expect(workspace.focusWorkspace())
        try await normalizeLayoutReasonOfNewlyVisibleWorkspaces()
        try await workspace.layoutWorkspace()
        #expect(fullscreen.parent === workspace.macOsNativeFullscreenWindowsContainer)
        assertEquals(window.sentFrames.last?.size?.width, 1920)
    }
}
