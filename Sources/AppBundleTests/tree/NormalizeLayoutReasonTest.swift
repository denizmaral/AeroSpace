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
