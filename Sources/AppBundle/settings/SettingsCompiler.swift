import AppKit
import Common
import HotKey
import OrderedCollections

/// A part of the settings that can't be compiled: e.g. an invalid custom command line, or a window title pattern that
/// isn't a regular expression. The part is left out, the rest works
struct SettingsProblem: Equatable, Sendable, CustomStringConvertible {
    /// Where, for the settings window: e.g. "Shortcuts › main › ctrl-alt-h"
    let location: String
    let message: String

    var description: String { "\(location): \(message)" }
}

extension Settings {
    /// The runtime config. Actions go through the command parser of the engine (``Action/commandLine``)
    ///
    /// - Parameter keyForCharacter: the key that types a character, for the shortcuts of the workspaces. The keyboard layout
    ///   of macOS by default
    @MainActor
    func compile(keyForCharacter: @MainActor (String) -> Key? = { KeyLabels.key(typing: $0) }) -> (config: Config, problems: [SettingsProblem]) {
        var problems: [SettingsProblem] = []
        var config = Config()
        config.configVersion = .max

        config.startAtLogin = general.startAtLogin
        config.focusFollowsMouse.enabled = general.focusFollowsMouse
        config.newWindowPlacement = general.newWindowPlacement
        config.defaultRootContainerLayout = general.defaultRootLayout
        config.defaultRootContainerOrientation = general.defaultRootOrientation
        config.enableNormalizationFlattenContainers = general.flattenContainers
        config.enableNormalizationOppositeOrientationForNestedContainers = general.oppositeOrientationForNestedContainers
        config.accordionPadding = general.accordionPadding
        config.automaticallyUnhideMacosHiddenApps = general.automaticallyUnhideMacosHiddenApps
        config.keyMapping = KeyMapping(preset: general.keyboardLayout)

        let gaps = appearance.gaps
        config.gaps = Gaps(
            inner: .init(vertical: gaps.innerVertical, horizontal: gaps.innerHorizontal),
            outer: .init(left: gaps.outerLeft, bottom: gaps.outerBottom, top: gaps.outerTop, right: gaps.outerRight),
        )
        let border = appearance.focusBorder
        config.focusBorder = FocusBorder(enabled: border.isEnabled, color: border.color.runtimeColor, width: border.width, radius: border.radius)

        config.persistentWorkspaces = OrderedSet(workspaces.persistent)
        for assignment in workspaces.monitorAssignments {
            config.workspaceToMonitorForceAssignment[assignment.workspace] = assignment.monitors.compactMap { selector in
                let description = selector.runtimeDescription
                if description == nil {
                    problems.append(.init(location: "Workspaces › \(assignment.workspace)", message: "Invalid monitor name pattern"))
                }
                return description
            }
        }

        let keyNames = KeyNames.of(general.keyboardLayout)
        let workspaceBindings = workspaceShortcutBindings(keyNames, keyForCharacter, &problems)
        for mode in modes {
            var bindings: [String: HotkeyBinding] = mode.name == mainModeId ? workspaceBindings : [:]
            for shortcut in mode.shortcuts {
                let notation = keyNames.notation(shortcut.chord)
                let location = "Shortcuts › \(mode.name) › \(notation)"
                let binding = HotkeyBinding(
                    shortcut.chord.modifiers.eventFlags,
                    shortcut.chord.key,
                    compileActions(shortcut.actions, location, &problems),
                    descriptionWithKeyNotation: notation,
                )
                if let existing = bindings[binding.descriptionWithKeyCode] {
                    let isWorkspaceShortcut = mode.name == mainModeId && workspaceBindings[binding.descriptionWithKeyCode] == existing
                    problems.append(.init(location: location, message: isWorkspaceShortcut ? "It's also the shortcut of a workspace" : "The shortcut is used twice"))
                }
                bindings[binding.descriptionWithKeyCode] = binding
            }
            config.modes[mode.name] = Mode(bindings: bindings)
        }

        for (index, rule) in windowRules.enumerated() {
            let location = "Window rules › \(index + 1)"
            guard let matcher = rule.condition.runtimeMatcher(location, &problems) else { continue }
            config.onWindowDetected.append(WindowDetectedCallback(
                matcher: .legacy(matcher),
                checkFurtherCallbacks: rule.checkFurtherRules,
                rawRun: compileActions(rule.actions, location, &problems),
            ))
        }

        config.afterStartupCommand = compileActions(automation.afterStartup, "Automation › After startup", &problems)
        config.onFocusChanged = compileActions(automation.onFocusChanged, "Automation › Focus changed", &problems)
        config.onFocusedMonitorChanged = compileActions(automation.onFocusedMonitorChanged, "Automation › Focused monitor changed", &problems)
        config.onModeChanged = compileActions(automation.onModeChanged, "Automation › Mode changed", &problems)

        if !modes.contains(where: { $0.name == mainModeId }) {
            problems.append(.init(location: "Shortcuts", message: "The '\(mainModeId)' mode is missing"))
        }
        return (config, problems)
    }
}

/// Actions run one after the other, like a list of command lines
@MainActor
private func compileActions(_ actions: [Action], _ location: String, _ problems: inout [SettingsProblem]) -> Shell<any Command> {
    let shells = actions.compactMap { action -> Shell<any Command>? in
        switch parseCommand(action.commandLine, allowExecAndForget: true, allowEval: false) {
            case .cmd(let shell): return shell
            case .help: return nil
            case .failure(let failure):
                problems.append(.init(location: location, message: failure.msg))
                return nil
        }
    }
    return .newCompound(shells, Shell<any Command>.seq)
}

extension BorderColor {
    fileprivate var runtimeColor: FocusBorderColor {
        switch self {
            case .solid(let color): .solid(color.value)
            case .gradient(let start, let end, let direction):
                .gradient(start: start.value, end: end.value, fromTopLeft: direction == .topLeftToBottomRight)
        }
    }
}

extension MonitorSelector {
    fileprivate var runtimeDescription: MonitorDescription? {
        switch self {
            case .main: .main
            case .secondary: .secondary
            case .number(let number): .sequenceNumber(number)
            case .nameMatching(let pattern): .pattern(pattern)
        }
    }
}

extension Settings.WindowCondition {
    fileprivate func runtimeMatcher(_ location: String, _ problems: inout [SettingsProblem]) -> LegacyWindowDetectedCallbackMatcher? {
        func regex(_ pattern: String?, _ name: String) -> CaseInsensitiveRegex?? {
            guard let pattern else { return .some(nil) }
            switch CaseInsensitiveRegex.new(pattern) {
                case .success(let regex): return .some(regex)
                case .failure(let message):
                    problems.append(.init(location: location, message: "\(name): \(message)"))
                    return nil
            }
        }
        guard let appName = regex(appNamePattern, "App name"), let windowTitle = regex(windowTitlePattern, "Window title") else { return nil }
        return LegacyWindowDetectedCallbackMatcher(
            appId: appBundleId,
            appNameRegexSubstring: appName,
            windowTitleRegexSubstring: windowTitle,
            workspace: workspace,
            duringAeroSpaceStartup: duringStartup,
        )
    }
}

extension KeyChord.Modifiers {
    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.option) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.command) { flags.insert(.command) }
        return flags
    }

    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
    }
}

/// The names of the keys in a keyboard layout preset, e.g. `ctrl-alt-period`
struct KeyNames {
    private let nameOfKey: [Key: String]

    @MainActor private static var cache: [KeyMapping.Preset: KeyNames] = [:]

    /// Built once per preset: it sorts the whole preset
    @MainActor
    static func of(_ preset: KeyMapping.Preset) -> KeyNames {
        if let names = cache[preset] { return names }
        let names = KeyNames(preset)
        cache[preset] = names
        return names
    }

    init(_ preset: KeyMapping.Preset) {
        var nameOfKey: [Key: String] = [:]
        // Several names can stand for one key: the shortest, then alphabetically first
        for (name, key) in getKeysPreset(preset).sorted(by: { ($0.key.count, $0.key) < ($1.key.count, $1.key) }) where nameOfKey[key] == nil {
            nameOfKey[key] = name
        }
        self.nameOfKey = nameOfKey
    }

    func name(_ key: Key) -> String { nameOfKey[key] ?? key.description }

    /// Modifiers in the order of the documentation: cmd, ctrl, alt, shift
    func notation(_ chord: KeyChord) -> String {
        var parts: [String] = []
        if chord.modifiers.contains(.command) { parts.append("cmd") }
        if chord.modifiers.contains(.control) { parts.append("ctrl") }
        if chord.modifiers.contains(.option) { parts.append("alt") }
        if chord.modifiers.contains(.shift) { parts.append("shift") }
        parts.append(name(chord.key))
        return parts.joined(separator: "-")
    }
}

extension Settings {
    /// Go to / move the window to every workspace whose name is one key. Workspaces without such a key are left out
    @MainActor
    private func workspaceShortcutBindings(
        _ keyNames: KeyNames,
        _ keyForCharacter: @MainActor (String) -> Key?,
        _ problems: inout [SettingsProblem],
    ) -> [String: HotkeyBinding] {
        let location = "Shortcuts › \(mainModeId) › Workspaces"
        var goTo = workspaceShortcuts.goTo
        var moveWindowTo = workspaceShortcuts.moveWindowTo
        if goTo?.isEmpty == true || moveWindowTo?.isEmpty == true {
            problems.append(.init(location: location, message: "A modifier key is needed: a key alone would be taken from typing"))
            if goTo?.isEmpty == true { goTo = nil }
            if moveWindowTo?.isEmpty == true { moveWindowTo = nil }
        }
        if let goTo, goTo == moveWindowTo {
            problems.append(.init(location: location, message: "Going to a workspace and moving a window there need different modifier keys"))
            moveWindowTo = nil
        }
        var bindings: [String: HotkeyBinding] = [:]
        for (modifiers, action) in [(goTo, Action.workspace), (moveWindowTo, Action.moveWindowToWorkspace)] {
            guard let modifiers else { continue }
            for name in workspaces.persistent where name.count == 1 {
                guard let key = keyForCharacter(name),
                      case .cmd(let shell) = parseCommand(action(name).commandLine, allowExecAndForget: false, allowEval: false)
                else { continue }
                let chord = KeyChord(modifiers, key)
                let binding = HotkeyBinding(modifiers.eventFlags, key, shell, descriptionWithKeyNotation: keyNames.notation(chord))
                bindings[binding.descriptionWithKeyCode] = binding
            }
        }
        return bindings
    }
}
