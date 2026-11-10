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
