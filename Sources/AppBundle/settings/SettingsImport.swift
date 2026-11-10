import AppKit
import Common
import HotKey
import TOMLDecoder

/// Turns an AeroSpace TOML config into settings, once: when MarSpace has no settings yet. The file is only read (the
/// AeroSpace app from brew uses the same file).
///
/// Values come from the TOML parser (validated, typed). Commands come from the raw TOML, as written: each command line
/// becomes a typed action if it runs exactly the same command, otherwise a custom command line
enum SettingsImport {
    /// - Returns: the settings, and what couldn't be taken over
    @MainActor
    static func settings(fromToml toml: String) -> (settings: Settings, problems: [String]) {
        let parsed = parseConfig(toml)
        var problems = parsed.errors.map { $0.description(.error) }
        let config = parsed.config
        let raw = rawTable(toml)
        var settings = Settings()

        settings.general = Settings.General(
            startAtLogin: config.startAtLogin,
            focusFollowsMouse: config.focusFollowsMouse.enabled,
            newWindowPlacement: config.newWindowPlacement,
            defaultRootLayout: config.defaultRootContainerLayout,
            defaultRootOrientation: config.defaultRootContainerOrientation,
            flattenContainers: config.enableNormalizationFlattenContainers,
            oppositeOrientationForNestedContainers: config.enableNormalizationOppositeOrientationForNestedContainers,
            accordionPadding: config.accordionPadding,
            automaticallyUnhideMacosHiddenApps: config.automaticallyUnhideMacosHiddenApps,
            keyboardLayout: config.keyMapping.preset,
        )
        if raw["key-mapping"]?.asDictOrNil?["key-notation-to-key-code"] != nil {
            problems.append("key-mapping.key-notation-to-key-code: custom key names aren't supported, the keys keep their codes")
        }

        func constant(_ value: DynamicConfigValue<Int>, _ name: String) -> Int {
            switch value {
                case .constant(let value): return value
                case .perMonitor(_, let defaultValue):
                    problems.append("gaps.\(name): values per monitor aren't supported yet, \(defaultValue) is used for all monitors")
                    return defaultValue
            }
        }
        settings.appearance.gaps = Settings.Appearance.Gaps(
            innerHorizontal: constant(config.gaps.inner.horizontal, "inner.horizontal"),
            innerVertical: constant(config.gaps.inner.vertical, "inner.vertical"),
            outerLeft: constant(config.gaps.outer.left, "outer.left"),
            outerRight: constant(config.gaps.outer.right, "outer.right"),
            outerTop: constant(config.gaps.outer.top, "outer.top"),
            outerBottom: constant(config.gaps.outer.bottom, "outer.bottom"),
        )
        let border = config.focusBorder
        settings.appearance.focusBorder = Settings.Appearance.FocusBorder(
            isEnabled: border.enabled,
            color: BorderColor(border.color),
            width: border.width,
            radius: border.radius,
        )

        settings.workspaces.persistent = Array(config.persistentWorkspaces)
        settings.workspaces.monitorAssignments = config.workspaceToMonitorForceAssignment
            .sorted { $0.key < $1.key }
            .map { Settings.MonitorAssignment(workspace: $0.key, monitors: $0.value.map(MonitorSelector.init)) }

        let keyNotations = config.keyMapping.resolve()
        settings.modes = (raw["mode"]?.asDictOrNil ?? [:]).map { name, rawMode in
            let rawBindings = rawMode.asDictOrNil?["binding"]?.asDictOrNil ?? [:]
            let shortcuts = rawBindings.compactMap { notation, rawCommands -> Settings.Shortcut? in
                guard case .success(let (modifiers, key)) = parseBinding(notation, .emptyRoot, keyNotations) else { return nil }
                return Settings.Shortcut(chord: KeyChord(KeyChord.Modifiers(modifiers), key), actions: actions(rawCommands))
            }
            return Settings.BindingMode(name: name, shortcuts: shortcuts)
        }
        if settings.modes.isEmpty { settings.modes = [Settings.BindingMode(name: mainModeId)] }

        settings.windowRules = (raw["on-window-detected"]?.asArrayOrNil ?? []).enumerated().compactMap { index, rawRule in
            guard let rule = rawRule.asDictOrNil else { return nil }
            // A condition that isn't taken over completely would match more windows (a missing one: every window). The
            // rule is left out then. E.g. `if = 'test %{app-bundle-id} = …'`, a shell condition
            let supported: Set = ["app-id", "app-name-regex-substring", "window-title-regex-substring", "workspace", "during-aerospace-startup"]
            guard let condition = rule["if"]?.asDictOrNil, Set(condition.keys).isSubset(of: supported) else {
                problems.append("on-window-detected[\(index)]: left out. Only conditions on the app, the window title, the workspace and " +
                    "the startup are supported, as a table (if.app-id = '…'). Add it again as a window rule in the settings")
                return nil
            }
            return Settings.WindowRule(
                condition: Settings.WindowCondition(
                    appBundleId: condition["app-id"]?.asStringOrNil,
                    appNamePattern: condition["app-name-regex-substring"]?.asStringOrNil,
                    windowTitlePattern: condition["window-title-regex-substring"]?.asStringOrNil,
                    workspace: condition["workspace"]?.asStringOrNil,
                    duringStartup: condition["during-aerospace-startup"]?.asBoolOrNil,
                ),
                actions: rule["run"].map(actions) ?? [],
                checkFurtherRules: rule["check-further-callbacks"]?.asBoolOrNil ?? false,
            )
        }

        settings.automation = Settings.Automation(
            afterStartup: raw["after-startup-command"].map(actions) ?? [],
            onFocusChanged: raw["on-focus-changed"].map(actions) ?? [],
            onFocusedMonitorChanged: raw["on-focused-monitor-changed"].map(actions) ?? [],
            onModeChanged: raw["on-mode-changed"].map(actions) ?? [],
        )
        for key in ["exec-on-workspace-change", "exec"] where raw[key] != nil {
            problems.append("\(key): not supported, it was left out")
        }
        // Like settings of the first schema: the workspace shortcuts come from the shortcuts of the config
        settings.schemaVersion = 1
        settings.workspaceShortcuts = Settings.WorkspaceShortcuts(goTo: nil, moveWindowTo: nil)
        SettingsMigration.migrate(&settings)
        return (settings, problems)
    }

    /// A command line, or a list of command lines run one after the other
    private static func actions(_ raw: OrderedJson) -> [Action] {
        if let line = raw.asStringOrNil { return line.isEmpty ? [] : [Action(commandLine: line)] }
        return (raw.asArrayOrNil ?? []).compactMap { $0.asStringOrNil.map(Action.init(commandLine:)) }
    }

    /// The text is TOML (not necessarily a valid config)
    static func isToml(_ toml: String) -> Bool {
        (try? TOMLTable(source: toml)) != nil
    }

    private static func rawTable(_ toml: String) -> OrderedJson.JsonDict {
        var errors: [ConfigParseDiagnostic] = []
        guard let dict: [String: Any] = try? .init(TOMLTable(source: toml)) else { return [:] }
        return tomlAnyToOrderedJsonRecursive(any: dict, .emptyRoot, &errors)?.asDictOrNil ?? [:]
    }
}

extension BorderColor {
    fileprivate init(_ color: FocusBorderColor) {
        self = switch color {
            case .solid(let value): .solid(ARGB(value))
            case .gradient(let start, let end, let fromTopLeft):
                .gradient(start: ARGB(start), end: ARGB(end), direction: fromTopLeft ? .topLeftToBottomRight : .topRightToBottomLeft)
        }
    }
}

extension MonitorSelector {
    fileprivate init(_ description: MonitorDescription) {
        self = switch description {
            case .main: .main
            case .secondary: .secondary
            case .sequenceNumber(let number): .number(number)
            case .pattern(let regex): .nameMatching(regex.origin)
        }
    }
}
