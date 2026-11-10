import AppKit
import Common
import HotKey
import OrderedCollections

/// The configuration of the engine, compiled from the settings (``SettingsStore``). Until they are applied at startup:
/// nothing bound, the defaults of the engine
@MainActor var config = Config()
/// `aerospace config --config-path`: the settings file
@MainActor var configUrl: URL = SettingsRepository.applicationSupport.fileUrl

struct Config: Withable {
    var afterStartupCommand: Shell<any Command> = .empty
    var enableNormalizationFlattenContainers: Bool = true
    var defaultRootContainerLayout: Layout = .tiles
    var defaultRootContainerOrientation: DefaultContainerOrientation = .auto
    var newWindowPlacement: NewWindowPlacement = .dwindle
    var startAtLogin: Bool = false
    var automaticallyUnhideMacosHiddenApps: Bool = false
    var accordionPadding: Int = 30
    var enableNormalizationOppositeOrientationForNestedContainers: Bool = true
    var persistentWorkspaces: OrderedSet<String> = []
    var focusFollowsMouse: Bool = false
    var focusBorder: FocusBorder = FocusBorder()

    var onFocusChanged: Shell<any Command> = .empty
    var onFocusedMonitorChanged: Shell<any Command> = .empty

    var gaps: Gaps = .zero
    var workspaceToMonitorForceAssignment: [String: [MonitorDescription]] = [:]
    var modes: [String: Mode] = [:]
    var onWindowDetected: [WindowDetectedCallback] = []
    var onModeChanged: Shell<any Command> = .empty
}


enum DefaultContainerOrientation: String {
    case horizontal, vertical, auto
}

enum NewWindowPlacement: String {
    /// The new window is put next to the most recent window in the same container (i3-like)
    case i3
    /// The new window splits the most recent tiling window in half (Hyprland-like dwindle layout)
    case dwindle
    /// The new window splits the largest tiling window in half. E.g., 4 windows are arranged in a 2x2 grid
    case balanced
}
