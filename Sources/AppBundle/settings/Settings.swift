import AppKit
import Common
import HotKey

/// Everything the user can configure. It's edited in the settings window and stored by ``SettingsStore``: the user never
/// edits a file. The runtime ``Config`` is compiled from it (``Settings/compile()``).
///
/// Typed throughout: actions, keys, layouts and directions are enums. Strings are only user data: workspace and mode
/// names, app bundle ids, title patterns, and custom command lines (the escape hatch for anything without a typed action)
struct Settings: Codable, Sendable, Equatable {
    /// 2: the shortcuts of the workspaces are generated (``workspaceShortcuts``)
    static let currentSchemaVersion = 2

    var schemaVersion = Settings.currentSchemaVersion
    var general = General()
    var appearance = Appearance()
    var modes: [BindingMode] = [BindingMode(name: mainModeId)]
    var workspaceShortcuts = WorkspaceShortcuts()
    var windowRules: [WindowRule] = []
    var workspaces = Workspaces()
    var automation = Automation()

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
        var keyboardLayout: KeyMapping.Preset = .qwerty
    }

    struct Appearance: Codable, Sendable, Equatable {
        var gaps = Gaps()
        var focusBorder = FocusBorder()

        struct Gaps: Codable, Sendable, Equatable {
            var innerHorizontal = 0
            var innerVertical = 0
            var outerLeft = 0
            var outerRight = 0
            var outerTop = 0
            var outerBottom = 0
        }

        struct FocusBorder: Codable, Sendable, Equatable {
            var isEnabled = false
            var color: BorderColor = .solid(ARGB(0xFF33_CCFF))
            var width = 4
            var radius = 12
        }
    }

    /// Shortcuts for every workspace whose name is one key (1 … 9, A … Z): these modifiers and the key that types the name on
    /// the keyboard layout of macOS. nil: no such shortcuts
    struct WorkspaceShortcuts: Codable, Sendable, Equatable {
        var goTo: KeyChord.Modifiers? = [.control, .option]
        var moveWindowTo: KeyChord.Modifiers? = [.control, .option, .shift]
    }

    struct BindingMode: Codable, Sendable, Equatable, Identifiable {
        var name: String
        var shortcuts: [Shortcut] = []

        var id: String { name }
    }

    struct Shortcut: Codable, Sendable, Equatable {
        var chord: KeyChord
        var actions: [Action]
    }

    /// The window rule runs its actions when a matching window appears (on-window-detected)
    struct WindowRule: Codable, Sendable, Equatable {
        var condition = WindowCondition()
        var actions: [Action] = []
        var checkFurtherRules = false
    }

    /// All the set fields must match
    struct WindowCondition: Codable, Sendable, Equatable {
        var appBundleId: String? = nil
        /// Case-insensitive regular expression, matches a substring
        var appNamePattern: String? = nil
        /// Case-insensitive regular expression, matches a substring
        var windowTitlePattern: String? = nil
        var workspace: String? = nil
        var duringStartup: Bool? = nil
    }

    struct Workspaces: Codable, Sendable, Equatable {
        /// Kept even when they are empty, in this order
        var persistent: [String] = []
        var monitorAssignments: [MonitorAssignment] = []
    }

    /// The workspace is shown on the first of the monitors that is connected
    struct MonitorAssignment: Codable, Sendable, Equatable {
        var workspace: String
        var monitors: [MonitorSelector]
    }

    struct Automation: Codable, Sendable, Equatable {
        var afterStartup: [Action] = []
        var onFocusChanged: [Action] = []
        var onFocusedMonitorChanged: [Action] = []
        var onModeChanged: [Action] = []
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
extension KeyMapping.Preset: Codable {}

extension Settings {
    /// Settings of an older MarSpace miss newer fields: they get their defaults (a migration may fill them, see
    /// ``SettingsMigration``)
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        general = try container.decodeIfPresent(General.self, forKey: .general) ?? defaults.general
        appearance = try container.decodeIfPresent(Appearance.self, forKey: .appearance) ?? defaults.appearance
        modes = try container.decodeIfPresent([BindingMode].self, forKey: .modes) ?? defaults.modes
        workspaceShortcuts = try container.decodeIfPresent(WorkspaceShortcuts.self, forKey: .workspaceShortcuts)
            ?? WorkspaceShortcuts(goTo: nil, moveWindowTo: nil)
        windowRules = try container.decodeIfPresent([WindowRule].self, forKey: .windowRules) ?? defaults.windowRules
        workspaces = try container.decodeIfPresent(Workspaces.self, forKey: .workspaces) ?? defaults.workspaces
        automation = try container.decodeIfPresent(Automation.self, forKey: .automation) ?? defaults.automation
    }
}
