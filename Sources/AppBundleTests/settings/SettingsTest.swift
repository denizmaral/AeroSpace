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

    @Test func testImportOfTheDefaultConfigCompilesToTheSameConfig() throws {
        try assertParity(String(contentsOf: projectRoot.appending(path: "docs/config-examples/default-config.toml"), encoding: .utf8))
    }

    /// A copy of a real config: two modes, 85 shortcuts, window rules, a gradient border, gaps, callbacks
    @Test func testImportOfAUserConfigCompilesToTheSameConfig() throws {
        try assertParity(String(contentsOf: projectRoot.appending(path: "test-fixtures/user-config.toml"), encoding: .utf8))
    }

    @Test func testImportTurnsCommandLinesIntoTypedActions() throws {
        let toml = try String(contentsOf: projectRoot.appending(path: "test-fixtures/user-config.toml"), encoding: .utf8)
        let settings = SettingsImport.settings(fromToml: toml).settings
        let main = try #require(settings.modes.first { $0.name == "main" })
        let service = try #require(settings.modes.first { $0.name == "service" })

        func actions(_ mode: Settings.BindingMode, _ modifiers: KeyChord.Modifiers, _ key: Key) -> IdentifiedList<Action>? {
            mode.shortcuts.first { $0.chord == KeyChord(modifiers, key) }?.actions
        }
        assertEquals(actions(main, [.control, .option], .h), [.focus(.left)])
        // The 61 shortcuts of the workspaces (30 go to, 31 move) are generated now: the same modifiers, the key of the name
        assertEquals(settings.workspaceShortcuts, Settings.WorkspaceShortcuts(goTo: [.control, .option], moveWindowTo: [.control, .option, .shift]))
        assertNil(actions(main, [.control, .option, .shift], .b))
        assertEquals(main.shortcuts.count, 16)
        assertEquals(actions(main, [.command, .shift], .f), [.fullscreen(.marSpace)])
        assertEquals(actions(main, [.control, .option], .minus), [.resize(.smart, .subtract(50))])
        assertEquals(actions(main, [.control, .option, .shift], .tab), [.moveWorkspaceToMonitor(.next, wrapAround: true)])
        assertEquals(actions(service, [], .escape), [.reloadSettings, .enterMode("main")])
        assertEquals(settings.windowRules.first?.condition.appBundleId, "com.apple.Terminal")
        assertEquals(settings.windowRules.first?.actions, [.moveWindowToWorkspace("T")])
        assertEquals(settings.automation.onFocusedMonitorChanged, [.moveMouse(.monitorLazyCenter)])
        // Nothing of this config needs a custom command line
        let all = settings.modes.flatMap { $0.shortcuts.flatMap(\.actions) } + settings.windowRules.flatMap(\.actions)
        assertEquals(all.filter { if case .custom = $0 { true } else { false } }, [])
    }

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

    /// A window rule runs again for a window that is detected again (e.g. after a restart): a toggle took a fullscreen window
    /// out of its fullscreen. Rules of the second schema enter the fullscreen, shortcuts still toggle it
    @Test func testWindowRulesOfTheSecondSchemaEnterTheFullscreen() {
        var settings = Settings()
        settings.schemaVersion = 2
        settings.modes = [Settings.BindingMode(name: mainModeId, shortcuts: [
            Settings.Shortcut(chord: KeyChord([.command, .shift], .f), actions: [.fullscreen(.marSpace)]),
        ])]
        settings.windowRules = [Settings.WindowRule(
            condition: .init(appBundleId: "app.zen-browser.zen"),
            actions: [.moveWindowToWorkspace("B"), .fullscreen(.macOSNative)],
        )]
        SettingsMigration.migrate(&settings)
        assertEquals(settings.windowRules[0].actions, [.moveWindowToWorkspace("B"), .enterFullscreen(.macOSNative)])
        assertEquals(settings.modes[0].shortcuts[0].actions, [.fullscreen(.marSpace)])
        assertEquals(settings.compile().config.onWindowDetected.first?.run.shellOfCommandsDescription, "move-node-to-workspace B; macos-native-fullscreen on")
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

    /// Every gap and border value distinct, so that no field can be mixed up with another
    @Test func testImportOfDistinctAppearanceValues() throws {
        try assertParity("""
            config-version = 2
            gaps.inner.horizontal = 1
            gaps.inner.vertical = 2
            gaps.outer.left = 3
            gaps.outer.bottom = 4
            gaps.outer.top = 5
            gaps.outer.right = 6
            focus-border.enabled = true
            focus-border.color = 'gradient(top_right=0x11223344,bottom_left=0x55667788)'
            focus-border.width = 7
            focus-border.radius = 9
            accordion-padding = 11
            [mode.main.binding]
            alt-h = 'focus left'
            """)
    }

    @Test func testSettingsSurviveTheStorageFormat() throws {
        let toml = try String(contentsOf: projectRoot.appending(path: "test-fixtures/user-config.toml"), encoding: .utf8)
        let settings = SettingsImport.settings(fromToml: toml).settings
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

    private func assertParity(_ toml: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let expected = parseConfig(toml)
        assertEquals(expected.errors, [], sourceLocation: sourceLocation)
        let imported = SettingsImport.settings(fromToml: toml)
        assertEquals(imported.problems, [], sourceLocation: sourceLocation)
        // QWERTY, like the configs: the shortcuts of the workspaces use the keyboard layout of macOS otherwise
        let (config, problems) = imported.settings.compile(keyForCharacter: { getKeysPreset(.qwerty)[$0.lowercased()] })
        assertEquals(problems, [], sourceLocation: sourceLocation)
        let original = expected.config

        // Every shortcut of the config, with the same commands. Generated workspace shortcuts may come in addition (e.g. a
        // workspace that had a move shortcut but no go-to shortcut)
        assertEquals(Set(config.modes.keys), Set(original.modes.keys), sourceLocation: sourceLocation)
        for (name, mode) in original.modes {
            let compiled = config.modes[name]?.bindings ?? [:]
            for (key, binding) in mode.bindings {
                assertEquals(compiled[key], binding, additionalMsg: "\(name) \(key)", sourceLocation: sourceLocation)
            }
            for (key, binding) in compiled where mode.bindings[key] == nil {
                let isWorkspace = binding.commands.flatten().allSatisfy { $0 is WorkspaceCommand || $0 is MoveNodeToWorkspaceCommand }
                #expect(isWorkspace && name == mainModeId, "unexpected \(name) \(key)", sourceLocation: sourceLocation)
            }
        }
        assertEquals(config.onWindowDetected, original.onWindowDetected, sourceLocation: sourceLocation)
        assertEquals(config.gaps, original.gaps, sourceLocation: sourceLocation)
        assertEquals(config.focusBorder, original.focusBorder, sourceLocation: sourceLocation)
        assertEquals(config.keyMapping, original.keyMapping, sourceLocation: sourceLocation)
        assertEquals(config.persistentWorkspaces, original.persistentWorkspaces, sourceLocation: sourceLocation)
        assertEquals(config.workspaceToMonitorForceAssignment, original.workspaceToMonitorForceAssignment, sourceLocation: sourceLocation)
        assertEquals(config.startAtLogin, original.startAtLogin, sourceLocation: sourceLocation)
        assertEquals(config.focusFollowsMouse.enabled, original.focusFollowsMouse.enabled, sourceLocation: sourceLocation)
        assertEquals(config.newWindowPlacement, original.newWindowPlacement, sourceLocation: sourceLocation)
        assertEquals(config.defaultRootContainerLayout, original.defaultRootContainerLayout, sourceLocation: sourceLocation)
        assertEquals(config.defaultRootContainerOrientation, original.defaultRootContainerOrientation, sourceLocation: sourceLocation)
        assertEquals(config.enableNormalizationFlattenContainers, original.enableNormalizationFlattenContainers, sourceLocation: sourceLocation)
        assertEquals(
            config.enableNormalizationOppositeOrientationForNestedContainers,
            original.enableNormalizationOppositeOrientationForNestedContainers,
            sourceLocation: sourceLocation,
        )
        assertEquals(config.accordionPadding, original.accordionPadding, sourceLocation: sourceLocation)
        assertEquals(config.automaticallyUnhideMacosHiddenApps, original.automaticallyUnhideMacosHiddenApps, sourceLocation: sourceLocation)
        for (compiled, parsed) in [
            (config.afterStartupCommand, original.afterStartupCommand), (config.onFocusChanged, original.onFocusChanged),
            (config.onFocusedMonitorChanged, original.onFocusedMonitorChanged), (config.onModeChanged, original.onModeChanged),
        ] {
            #expect(compiled.strictEquals(parsed), sourceLocation: sourceLocation)
        }
    }
}

/// The first launch takes the AeroSpace config over once. What can't be taken over completely is left out, loudly
@MainActor
@Suite(.serializedGlobally)
struct SettingsImportTest {
    init() { setUpWorkspacesForTests() }

    private let directory = FileManager.default.temporaryDirectory.appending(path: "SettingsImportTest-\(UUID().uuidString)")

    /// A shell condition (recommended by AeroSpace's guide) or no condition: the rule would match every window
    @Test func testRulesWhoseConditionCantBeTakenOverAreLeftOut() {
        let imported = SettingsImport.settings(fromToml: """
            [[on-window-detected]]
            if = 'test %{app-bundle-id} = org.alacritty'
            run = 'move-node-to-workspace T'

            [[on-window-detected]]
            run = 'layout floating'

            [[on-window-detected]]
            if.app-id = 'com.apple.Terminal'
            run = 'move-node-to-workspace T'
            """)
        assertEquals(imported.settings.windowRules.map(\.condition.appBundleId), ["com.apple.Terminal"])
        assertEquals(imported.problems.count(where: { $0.contains("left out") }), 2)
    }

    /// Not saved: the next launch tries again, e.g. after the config was fixed
    @Test func testAConfigThatIsNotTomlIsNotTakenOver() throws {
        let store = SettingsRepository(directory: directory)
        let url = directory.appending(path: "aerospace.toml")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for content in [Data("[mode.main.binding\nalt-h = 'focus left'".utf8), Data([0xFF, 0xFE, 0x00, 0x41])] {
            try content.write(to: url)
            let (settings, notices) = importSettings(from: url, store: store, dryRun: false)
            assertEquals(settings, defaultSettings())
            #expect(notices.first?.contains("can't be read as a TOML config") == true)
            assertEquals(store.load(), .none)
        }

        try Data("[mode.main.binding]\nalt-h = 'focus left'".utf8).write(to: url)
        let (imported, _) = importSettings(from: url, store: store, dryRun: false)
        assertEquals(imported.modes.first?.shortcuts.first?.actions, [.focus(.left)])
        assertEquals(store.load(), .loaded(imported))
    }
}
