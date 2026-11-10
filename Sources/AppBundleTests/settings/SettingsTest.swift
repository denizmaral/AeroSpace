@testable import AppBundle
import Common
import Foundation
import HotKey
import Testing

/// The settings compile to the config of the engine: typed actions build their commands, invalid parts are problems
@MainActor
@Suite(.serializedGlobally)
struct SettingsTest {
    init() { setUpWorkspacesForTests() }

    /// A typed action builds its command without the parser: exactly the command that its command line parses to, and it
    /// prints the same (`aerospace config`, the logs)
    @Test func testTypedActionsBuildTheCommandsOfTheirCommandLines() {
        let actions: [Action] = [
            .focus(.left), .focus(.down), .move(.up), .move(.right), .joinWith(.left), .joinWith(.down),
            .resize(.smart, .add(50)), .resize(.width, .subtract(50)), .resize(.height, .set(300)), .resize(.smartOpposite, .add(1)),
            .workspace("T"), .workspace("1#main"), .workspace("A+B"), .workspaceBackAndForth,
            .moveWindowToWorkspace("B"), .moveWindowToWorkspace("1#main"),
            .moveWorkspaceToMonitor(.next, wrapAround: false), .moveWorkspaceToMonitor(.prev, wrapAround: true),
            .layout([.tiles, .accordion]), .layout([.horizontal, .vertical]), .layout([.floating, .tiling]), .layout([.tiling]),
            .fullscreen(.marSpace), .fullscreen(.macOSNative), .enterFullscreen(.marSpace), .enterFullscreen(.macOSNative),
            .exitFullscreen(.marSpace), .exitFullscreen(.macOSNative),
            .flattenWorkspaceTree, .balanceSizes, .closeWindow, .closeAllWindowsButCurrent, .enterMode("service"), .enterMode("main"),
            .reloadSettings,
        ] + MouseTarget.allCases.map(Action.moveMouse)
        assertEquals(Set(actions.map(ActionKind.init)), Set(ActionKind.allCases).subtracting([.custom]))
        for action in actions {
            guard case .cmd(let built) = action.command,
                  case .cmd(let parsed) = parseCommand(action.commandLine, allowExecAndForget: true, allowEval: false)
            else {
                Issue.record("'\(action.commandLine)' isn't a command")
                continue
            }
            #expect(built.strictEquals(parsed), "\(action.commandLine)")
            assertEquals(built.shellOfCommandsDescription, parsed.shellOfCommandsDescription)
        }
        assertEquals(Action.workspace("1#main").commandLine, "workspace '1#main'") // Not a comment
        assertEquals(Action.resize(.width, .add(50)).commandLine, "resize width +50")
        guard case .failure = Action.layout([]).command else { Issue.record("A layout command without a layout"); return }
    }

    /// A custom command line is parsed: flags without a typed action, sequences, quoting
    @Test func testCustomCommandLinesAreParsed() {
        for line in ["focus --boundaries workspace left", "exec-and-forget open -a Terminal", "mode main; focus left", "workspace next"] {
            guard case .cmd(let parsed) = parseCommand(line, allowExecAndForget: true, allowEval: false),
                  case .cmd(let custom) = Action.custom(line).command
            else {
                Issue.record("'\(line)' isn't a command")
                continue
            }
            #expect(custom.strictEquals(parsed), "\(line)")
        }
        guard case .help = Action.custom("mode --help").command else { Issue.record("Not the help"); return }
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
        let (config, problems) = Settings.defaults.compile(keyForCharacter: { keyNotationToKeyCode[$0.lowercased()] })
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
