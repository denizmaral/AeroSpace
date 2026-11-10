@testable import AppBundle
import Common
import Testing

/// An app opens on the workspace where the user put it with a shortcut (Mail on workspace M): visible and editable in the
/// settings, not remembered for moves by window rules or the CLI
@MainActor
@Suite(.serializedGlobally)
struct AppWorkspacesTest {
    init() { setUpWorkspacesForTests() }

    private let app = "bobko.AeroSpace.test-app" // The bundle id of TestApp

    @Test func testTheAppOpensOnItsWorkspaceWhenItStarts() {
        var settings = Settings()
        settings.appWorkspaces = [Settings.AppWorkspace(bundleId: "com.apple.mail", workspace: "M")]
        config = settings.compile().config
        assertEquals(config.appWorkspaces, ["com.apple.mail": "M"])
        assertEquals(appWorkspace(forNewWindowOf: "com.apple.mail", appIsStarting: true, isStartup: false), "M")
        assertEquals(appWorkspace(forNewWindowOf: "com.apple.mail", appIsStarting: false, isStartup: true), "M")
        assertNil(appWorkspace(forNewWindowOf: "com.apple.mail", appIsStarting: false, isStartup: false)) // A later window
        assertNil(appWorkspace(forNewWindowOf: "com.apple.Safari", appIsStarting: true, isStartup: false))
    }

    /// Only a move by a shortcut counts: not one by a window rule, nor by the CLI (no hotkey session)
    @Test func testOnlyMovesByAShortcutAreRemembered() async {
        let store = SettingsStore.shared
        store.update { $0.appWorkspaces = [] }
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        _ = window.focusWindow()

        await parseCommand("move-node-to-workspace by-cli").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(store.settings.appWorkspaces.count, 0)

        await $refreshSessionEvent.withValue(.hotkeyBinding) {
            await WindowRuleContext.$isRunning.withValue(true) {
                _ = await parseCommand("move-node-to-workspace by-rule").cmdOrDie.run(.defaultEnv.withWindowId(window.windowId), .emptyStdin)
            }
            assertEquals(store.settings.appWorkspaces.count, 0)

            _ = await parseCommand("move-node-to-workspace by-shortcut").cmdOrDie.run(.defaultEnv.withWindowId(window.windowId), .emptyStdin)
        }
        assertEquals(Array(store.settings.appWorkspaces), [Settings.AppWorkspace(bundleId: app, workspace: "by-shortcut")])
    }

    /// An app that a window rule places isn't remembered: the rule decides. A remembered app gets its new workspace
    @Test func testRememberedWorkspaces() {
        let store = SettingsStore(repository: nil, applyToEngine: { _ in })
        store.update { $0.windowRules = [Settings.WindowRule(condition: .init(appBundleId: "com.apple.Terminal"), actions: [.moveWindowToWorkspace("T")])] }
        store.remember("com.apple.Terminal", onWorkspace: "2")
        assertEquals(store.settings.appWorkspaces.count, 0)
        store.remember("com.apple.mail", onWorkspace: "1")
        store.remember("com.apple.mail", onWorkspace: "M")
        assertEquals(Array(store.settings.appWorkspaces), [Settings.AppWorkspace(bundleId: "com.apple.mail", workspace: "M")])
    }
}
