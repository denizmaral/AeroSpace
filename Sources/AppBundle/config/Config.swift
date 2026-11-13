import AppKit
import Common
import HotKey
import OrderedCollections

/// The configuration of the engine, compiled from the settings (``SettingsStore``). Until they are applied at startup:
/// nothing bound, the defaults of the engine
@MainActor var config = Config()
/// `aerospace config --config-path`: the settings file
@MainActor let configUrl: URL = SettingsRepository.applicationSupport.fileUrl

struct Config: Withable {
    var afterStartupCommand: Shell<any Command> = .empty
    var enableNormalizationFlattenContainers: Bool = true
    /// The layout of a workspace that `workspace-layout` didn't switch (see ``WorkspaceLayoutMemory/chosen``)
    var defaultWorkspaceLayout: WorkspaceLayout = .tiling
    /// The root container of a tiling workspace: tiles or accordion
    var defaultRootContainerLayout: Layout = .tiles
    var defaultRootContainerOrientation: DefaultContainerOrientation = .auto
    var newWindowPlacement: NewWindowPlacement = .dwindle
    var startAtLogin: Bool = false
    var automaticallyUnhideMacosHiddenApps: Bool = false
    var accordionPadding: Int = 30
    /// The length of a column of a scrolling workspace with weight 1, a share of the screen (see ``Layout/scrolling``)
    var scrollingColumnWidth: CGFloat = 0.5
    /// Two fingers sideways on the trackpad move through the columns of a scrolling workspace (see TrackpadColumnScrolling)
    var trackpadScrollsColumns: Bool = true
    /// Held while the fingers move through the columns: none, or e.g. Option (the gestures without it go to the apps)
    var trackpadScrollModifiers: CGEventFlags = []
    var enableNormalizationOppositeOrientationForNestedContainers: Bool = true
    var persistentWorkspaces: OrderedSet<String> = []
    var focusFollowsMouse: Bool = false
    var focusBorder: FocusBorder = FocusBorder()

    var onFocusChanged: Shell<any Command> = .empty
    var onFocusedMonitorChanged: Shell<any Command> = .empty

    var gaps: Gaps = .zero
    /// No outer gaps around the only tiling window of a workspace (Hyprland's "smart gaps")
    var smartGaps: Bool = false
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
