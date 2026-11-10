import AppKit
import Common
import HotKey

/// Everything the user can configure. It's edited in the settings window and stored by ``SettingsRepository``: the user never
/// edits a file. The runtime ``Config`` is compiled from it (``Settings/compile()``).
///
/// Typed throughout: actions, keys, layouts and directions are enums. Strings are only user data: workspace and mode
/// names, app bundle ids, title patterns, and custom command lines (the escape hatch for anything without a typed action)
@DecodableWithDefaults
struct Settings: Codable, Sendable, Equatable {
    /// 2: the shortcuts of the workspaces are generated (``workspaceShortcuts``)
    /// 3: window rules enter the fullscreen instead of toggling it
    static let currentSchemaVersion = 3

    var schemaVersion = Settings.currentSchemaVersion
    var general = General()
    var appearance = Appearance()
    var modes: [BindingMode] = [BindingMode(name: mainModeId)]
    var workspaceShortcuts = WorkspaceShortcuts()
    var windowRules: IdentifiedList<WindowRule> = []
    var workspaces = Workspaces()
    var automation = Automation()

    @DecodableWithDefaults
    struct General: Codable, Sendable, Equatable {
        var startAtLogin = false
        var focusFollowsMouse = false
        var newWindowPlacement: NewWindowPlacement = .dwindle
        var defaultRootLayout: Layout = .tiles
        var defaultRootOrientation: DefaultContainerOrientation = .auto
        var flattenContainers = true
        var oppositeOrientationForNestedContainers = true
        var accordionPadding = 30
        var automaticallyUnhideMacosHiddenApps = false
    }

    @DecodableWithDefaults
    struct Appearance: Codable, Sendable, Equatable {
        var gaps = Gaps()
        var focusBorder = FocusBorder()

        @DecodableWithDefaults
        struct Gaps: Codable, Sendable, Equatable {
            var innerHorizontal = 0
            var innerVertical = 0
            var outerLeft = 0
            var outerRight = 0
            var outerTop = 0
            var outerBottom = 0
            /// A workspace with one tiling window: the window fills the screen, without the gaps at the screen edges
            var noneAroundSingleWindow = false
        }

        @DecodableWithDefaults
        struct FocusBorder: Codable, Sendable, Equatable {
            var isEnabled = false
            var color: BorderColor = .solid(ARGB(0xFF33_CCFF))
            var width = 4
            var radius = 12
        }
    }

    /// Shortcuts for every workspace whose name is one key (1 … 9, A … Z): these modifiers and the key that types the name on
    /// the keyboard layout of macOS. nil: no such shortcuts
    @DecodableWithDefaults
    struct WorkspaceShortcuts: Codable, Sendable, Equatable {
        var goTo: KeyChord.Modifiers? = [.control, .option]
        var moveWindowTo: KeyChord.Modifiers? = [.control, .option, .shift]
    }

    @DecodableWithDefaults
    struct BindingMode: Codable, Sendable, Equatable, Identifiable {
        var name: String
        var shortcuts: IdentifiedList<Shortcut> = []

        var id: String { name }
    }

    @DecodableWithDefaults
    struct Shortcut: Codable, Sendable, Equatable {
        var chord: KeyChord
        var actions: IdentifiedList<Action> = []
    }

    /// The window rule runs its actions when a matching window appears (on-window-detected)
    @DecodableWithDefaults
    struct WindowRule: Codable, Sendable, Equatable {
        var condition = Settings.WindowCondition()
        var actions: IdentifiedList<Action> = []
        var checkFurtherRules = false
    }

    /// All the set fields must match
    @DecodableWithDefaults
    struct WindowCondition: Codable, Sendable, Equatable {
        var appBundleId: String? = nil
        /// Case-insensitive regular expression, matches a substring
        var appNamePattern: String? = nil
        /// Case-insensitive regular expression, matches a substring
        var windowTitlePattern: String? = nil
        var workspace: String? = nil
        var duringStartup: Bool? = nil
    }

    @DecodableWithDefaults
    struct Workspaces: Codable, Sendable, Equatable {
        /// Kept even when they are empty, in this order
        var persistent: [String] = []
        var monitorAssignments: IdentifiedList<MonitorAssignment> = []
    }

    /// The workspace is shown on the first of the monitors that is connected
    @DecodableWithDefaults
    struct MonitorAssignment: Codable, Sendable, Equatable {
        var workspace: String
        var monitors: [MonitorSelector] = []
    }


    @DecodableWithDefaults
    struct Automation: Codable, Sendable, Equatable {
        var afterStartup: IdentifiedList<Action> = []
        var onFocusChanged: IdentifiedList<Action> = []
        var onFocusedMonitorChanged: IdentifiedList<Action> = []
        var onModeChanged: IdentifiedList<Action> = []
    }
}

/// 0xAARRGGBB
struct ARGB: Codable, Sendable, Equatable, Hashable {
    var value: UInt32

    init(_ value: UInt32) { self.value = value }
}

enum BorderColor: Codable, Sendable, Equatable {
    case solid(ARGB)
    case gradient(start: ARGB, end: ARGB, direction: GradientDirection)

    enum GradientDirection: String, Codable, Sendable, CaseIterable {
        case topLeftToBottomRight
        case topRightToBottomLeft
    }
}

enum MonitorSelector: Codable, Sendable, Equatable {
    case main
    case secondary
    /// 1-based, monitors sorted from left to right
    case number(Int)
    /// Case-insensitive regular expression for the monitor name
    case nameMatching(String)
}

/// A key and its modifiers. The key is stored by its virtual key code (the physical key), shown by the name of the
/// keyboard layout preset
struct KeyChord: Codable, Sendable, Equatable, Hashable {
    var modifiers: Modifiers
    var key: Key

    struct Modifiers: OptionSet, Codable, Sendable, Hashable {
        let rawValue: UInt8

        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    init(_ modifiers: Modifiers, _ key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    private enum CodingKeys: String, CodingKey { case modifiers, keyCode }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modifiers = try container.decode(Modifiers.self, forKey: .modifiers)
        let keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        guard let key = Key(carbonKeyCode: keyCode) else {
            throw DecodingError.dataCorruptedError(forKey: .keyCode, in: container, debugDescription: "Unknown key code \(keyCode)")
        }
        self.key = key
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(key.carbonKeyCode, forKey: .keyCode)
    }
}

extension NewWindowPlacement: Codable {}
extension Layout: Codable {}
extension DefaultContainerOrientation: Codable {}


extension Settings.Shortcut {
    /// Just added, without an action yet: it's shown, and the engine skips it (it doesn't take its keys)
    var isComplete: Bool { !actions.isEmpty }
}

extension Settings {
    /// The user moved a window of the app to a workspace with a shortcut: the window rule of the app moves its windows
    /// there, like a rule made in the settings window. Its existing rule (the one for the app alone) gets the workspace
    mutating func assign(_ bundleId: String, toWorkspace workspace: String) {
        let move = Action.moveWindowToWorkspace(workspace)
        guard let rule = windowRules.firstIndex(where: { $0.condition == WindowCondition(appBundleId: bundleId) }) else {
            windowRules.append(WindowRule(condition: WindowCondition(appBundleId: bundleId), actions: [move]))
            return
        }
        if let action = windowRules[rule].actions.firstIndex(where: { if case .moveWindowToWorkspace = $0 { true } else { false } }) {
            windowRules[rule].actions[action] = move
        } else {
            windowRules[rule].actions.insert(move, at: 0)
        }
    }
}

extension Settings.WindowRule {
    /// Just added, without an action yet: it's shown, and the engine skips it (it doesn't stop the next rules either)
    var isComplete: Bool { !actions.isEmpty }
}
