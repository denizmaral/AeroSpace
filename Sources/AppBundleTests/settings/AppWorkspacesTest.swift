@testable import AppBundle
import Common
import Testing

/// A window moved to a workspace with a shortcut makes it the window rule of its app ("Mail: move the window to workspace
/// M"), like a rule made in the settings window. Moves by window rules or the CLI don't
@MainActor
@Suite(.serializedGlobally)
struct AppWorkspacesTest {
    init() { setUpWorkspacesForTests() }

    private let app = "bobko.AeroSpace.test-app" // The bundle id of TestApp

    @Test func testAMoveMakesOrChangesTheRuleOfTheApp() {
        var settings = Settings()
        settings.windowRules = [
            Settings.WindowRule(condition: .init(appBundleId: "app.zen-browser.zen"), actions: [.moveWindowToWorkspace("B"), .enterFullscreen(.macOSNative)]),
            Settings.WindowRule(condition: .init(appBundleId: "com.apple.systempreferences"), actions: [.layout([.tiling])]),
            Settings.WindowRule(condition: .init(appBundleId: "com.apple.mail", windowTitlePattern: "Compose"), actions: [.layout([.floating])]),
        ]
        settings.assign("com.apple.mail", toWorkspace: "M") // Its rule with a title isn't the rule of the app
        settings.assign("app.zen-browser.zen", toWorkspace: "C") // Keeps entering the fullscreen
        settings.assign("com.apple.systempreferences", toWorkspace: "F")
        assertEquals(settings.windowRules.map(\.actions), [
            [.moveWindowToWorkspace("C"), .enterFullscreen(.macOSNative)],
            [.moveWindowToWorkspace("F"), .layout([.tiling])],
            [.layout([.floating])],
            [.moveWindowToWorkspace("M")],
        ])
        assertEquals(settings.windowRules.last?.condition, Settings.WindowCondition(appBundleId: "com.apple.mail"))
    }

    /// Only a move by a shortcut counts: not one by a window rule, nor by the CLI (no hotkey session)
    @Test func testOnlyMovesByAShortcutMakeARule() async {
        let store = SettingsStore.shared
        store.update { $0.windowRules = [] }
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        _ = window.focusWindow()

        await parseCommand("move-node-to-workspace by-cli").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(store.settings.windowRules.count, 0)

        await $refreshSessionEvent.withValue(.hotkeyBinding) {
            await WindowRuleContext.$isRunning.withValue(true) {
                _ = await parseCommand("move-node-to-workspace by-rule").cmdOrDie.run(.defaultEnv.withWindowId(window.windowId), .emptyStdin)
            }
            assertEquals(store.settings.windowRules.count, 0)

            _ = await parseCommand("move-node-to-workspace by-shortcut").cmdOrDie.run(.defaultEnv.withWindowId(window.windowId), .emptyStdin)
        }
        assertEquals(store.settings.windowRules.map(\.condition.appBundleId), [app])
        assertEquals(store.settings.windowRules.first?.actions, [.moveWindowToWorkspace("by-shortcut")])
        store.update { $0.windowRules = [] }
    }
}
