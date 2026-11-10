@testable import AppBundle
import Common
import Foundation
import HotKey
import Testing

/// The settings replace the TOML config. Importing a TOML config and compiling the settings must give exactly the config
/// that the TOML parser gives: nothing of the user's setup is lost
@MainActor
@Suite(.serializedGlobally)
struct SettingsTest {
    init() { setUpWorkspacesForTests() }

    @Test func testTypedActionsAndTheirCommandLines() {
        let actions: [Action] = [
            .focus(.up), .move(.down), .joinWith(.right), .resize(.width, .add(50)), .resize(.height, .set(300)),
            .workspace("T"), .workspace("my space"), .workspaceBackAndForth, .moveWindowToWorkspace("B"),
            .moveWorkspaceToMonitor(.prev, wrapAround: false), .layout([.floating, .tiling]), .fullscreen(.macOSNative),
            .enterFullscreen(.macOSNative), .exitFullscreen(.marSpace),
            .flattenWorkspaceTree, .balanceSizes, .closeWindow, .closeAllWindowsButCurrent, .enterMode("service"),
            .reloadSettings, .moveMouse(.windowLazyCenter),
        ]
        for action in actions {
            if case .workspace("my space") = action {
                assertEquals(action.commandLine, "workspace 'my space'")
                continue // A quoted line stays a custom command line when it's read back
            }
            assertEquals(Action(commandLine: action.commandLine), action)
            guard case .cmd = parseCommand(action.commandLine, allowExecAndForget: true, allowEval: false) else {
                Issue.record("'\(action.commandLine)' doesn't parse")
                continue
            }
        }
        // Flags without a typed action, sequences, quoting: custom command lines, as written
        for line in [
            "focus --boundaries workspace left", "exec-and-forget open -a Terminal", "workspace --auto-back-and-forth T", "mode main; focus left",
            "workspace 1 #1 is a comment", "workspace 1#main", "mode service#x", "mode --help", "workspace next", "move-node-to-workspace prev",
        ] {
            assertEquals(Action(commandLine: line), .custom(line))
        }
        assertEquals(Action(commandLine: "layout   tiles  accordion"), .layout([.tiles, .accordion]))
    }

    /// A name that the command language refuses or reads as something else (a direction) is a problem, not a surprise
    @Test func testInvalidWorkspaceNamesAreProblems() {
        var settings = Settings()
        settings.workspaceShortcuts = .init(goTo: nil, moveWindowTo: nil)
        settings.workspaces.persistent = ["1", "Mail Box", "next"]
        settings.modes = [Settings.BindingMode(name: mainModeId, shortcuts: [
            Settings.Shortcut(chord: KeyChord([.option], .n), actions: [.workspace("next")]),
            Settings.Shortcut(chord: KeyChord([.option], .m), actions: [.moveWindowToWorkspace("Mail Box")]),
        ])]
        let (config, problems) = settings.compile()
        assertEquals(problems.map(\.location), ["Workspaces › Mail Box", "Workspaces › next", "Shortcuts › main › alt-n", "Shortcuts › main › alt-m"])
        assertEquals(Array(config.persistentWorkspaces), ["1"])
        assertEquals(config.modes[mainModeId]?.bindings.count, 0)
    }

    /// A shortcut or a rule that was just added does nothing until an action is chosen: it doesn't take its keys, and the rule
    /// doesn't stop the next rules
    @Test func testAddedShortcutsAndRulesDoNothingYet() {
        var settings = Settings()
        settings.workspaceShortcuts = .init(goTo: nil, moveWindowTo: nil)
        settings.modes = [Settings.BindingMode(name: mainModeId, shortcuts: [Settings.Shortcut(chord: KeyChord([.control, .option], .f1), actions: [])])]
        settings.windowRules = [Settings.WindowRule(), Settings.WindowRule(condition: .init(appBundleId: "com.apple.mail"), actions: [.moveWindowToWorkspace("M")])]
        let (config, problems) = settings.compile()
        assertEquals(problems, [])
        assertEquals(config.modes[mainModeId]?.bindings.count, 0)
        assertEquals(config.onWindowDetected.count, 1) // Only the Mail rule
    }

    /// The settings of the first launch: valid, everything a new user needs (⌃⌥ shortcuts, workspaces, a service mode)
    @Test func testTheDefaults() {
        let (config, problems) = Settings.defaults.compile(keyForCharacter: { getKeysPreset(.qwerty)[$0.lowercased()] })
        assertEquals(problems, [])
        assertEquals(config.modes[mainModeId]?.bindings.count, 15 + 31 + 31) // The shortcuts, going to and moving to 31 workspaces
        assertEquals(config.modes["service"]?.bindings.count, 8)
        assertEquals(config.persistentWorkspaces.count, 31)
    }

    @Test func testSettingsSurviveTheStorageFormat() throws {
        var settings = Settings.defaults
        settings.windowRules = [Settings.WindowRule(condition: .init(appBundleId: "com.apple.mail"), actions: [.moveWindowToWorkspace("M")])]
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        assertEquals(try PropertyListDecoder().decode(Settings.self, from: encoder.encode(settings)), settings)
    }

    @Test func testInvalidPartsAreReportedAndLeftOut() {
        var settings = Settings()
        settings.modes = [Settings.BindingMode(name: "main", shortcuts: [
            Settings.Shortcut(chord: KeyChord([.option], .h), actions: [.custom("focus nowhere")]),
            Settings.Shortcut(chord: KeyChord([.option], .j), actions: [.focus(.down)]),
        ])]
        settings.windowRules = [Settings.WindowRule(condition: .init(windowTitlePattern: "(unclosed"), actions: [.focus(.left)])]
        let (config, problems) = settings.compile()
        assertEquals(problems.map(\.location), ["Shortcuts › main › alt-h", "Window rules › 1"])
        assertEquals(config.modes["main"]?.bindings.keys.sorted(), ["alt-j"]) // alt-h is left out
        assertEquals(config.onWindowDetected.count, 0)
    }
}
