@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct NormalizeLayoutReasonTest {
    init() { setUpWorkspacesForTests() }

    /// 2 AX calls per window per refresh session are saved for windows of invisible workspaces
    @Test func testWindowsOfInvisibleWorkspacesAreCheckedAtMostEvery5Seconds() async throws {
        let workspace = Workspace.get(byName: "invisible")
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        window.isMacosFullscreenForTest = true
        #expect(!workspace.isVisible)

        lastInvisibleWindowsNativeStateCheck = .now // They were checked just now
        try await normalizeLayoutReason()
        assertEquals(window.layoutReason, .standard)

        lastInvisibleWindowsNativeStateCheck = .now - .seconds(6)
        try await normalizeLayoutReason()
        assertEquals(window.layoutReason, .macos(prevParentKind: .tilingContainer))
        #expect(window.parent === workspace.macOsNativeFullscreenWindowsContainer)
    }

    /// E.g. "Minimize All": AX notifies about the native state change of a window of an invisible workspace. The window
    /// must be handled before the workspace is shown (otherwise it gets a tile and leaves a hole)
    @Test func testNotifiedWindowOfInvisibleWorkspaceIsCheckedRightAway() async throws {
        config.automaticallyUnhideMacosHiddenApps = true // The hidden app check needs MacApp
        let workspace = Workspace.get(byName: "invisible")
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let window2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        lastInvisibleWindowsNativeStateCheck = .now // The periodic check was just now

        window.isMacosFullscreenForTest = true
        window.isNativeStateCheckRequested = true // refreshObs: kAXWindowMiniaturizedNotification etc.
        try await normalizeLayoutReason()
        #expect(window.parent === workspace.macOsNativeFullscreenWindowsContainer)
        assertEquals(window.isNativeStateCheckRequested, false)

        #expect(workspace.focusWorkspace())
        try await workspace.layoutWorkspace()
        assertEquals(window2.sentFrames.last?.size?.width, 1920)
    }

    @Test func testWindowsOfVisibleWorkspacesAreAlwaysChecked() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        window.isMacosFullscreenForTest = true

        lastInvisibleWindowsNativeStateCheck = .now
        try await normalizeLayoutReason()
        #expect(window.parent === workspace.macOsNativeFullscreenWindowsContainer)
    }
}
