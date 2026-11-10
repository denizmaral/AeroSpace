@testable import AppBundle
import Common
import Testing

/// An app that the user moved to a workspace opens there again when it's launched again (Mail on workspace M)
@MainActor
@Suite(.serializedGlobally)
struct AppWorkspaceStoreTest {
    init() { setUpWorkspacesForTests() }

    @Test func testAMovedAppOpensOnItsWorkspaceWhenItStarts() async {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        _ = window.focusWindow()
        await parseCommand("move-node-to-workspace mail-test").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let app = window.app.rawAppBundleId

        assertEquals(AppWorkspaceStore.workspace(forNewWindowOf: app, appIsStarting: true, isStartup: false), "mail-test")
        assertEquals(AppWorkspaceStore.workspace(forNewWindowOf: app, appIsStarting: false, isStartup: true), "mail-test")
        assertNil(AppWorkspaceStore.workspace(forNewWindowOf: app, appIsStarting: false, isStartup: false)) // A later window
        assertNil(AppWorkspaceStore.workspace(forNewWindowOf: "com.example.never-moved", appIsStarting: true, isStartup: false))

        await parseCommand("move-node-to-workspace other-test").cmdOrDie.run(.defaultEnv.withWindowId(window.windowId), .emptyStdin)
        assertEquals(AppWorkspaceStore.workspace(forNewWindowOf: app, appIsStarting: true, isStartup: false), "other-test") // The last move
    }
}
