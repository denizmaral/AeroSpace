import SwiftUI

/// The look of the menu bar item, kept in the user defaults. Read once: the menu bar item is drawn from them after every
/// refresh session that changes what it shows
struct ExperimentalUISettings {
    var displayStyle: MenuBarStyle {
        didSet { UserDefaults.standard.setValue(displayStyle.rawValue, forKey: ExperimentalUISettingsItems.displayStyle.rawValue) }
    }
    /// The workspaces that the strips of the menu bar item show (pills, dots, i3), also when they are empty. None: all
    /// workspaces with windows. See ``MenuBarState/strip``
    var favoriteWorkspaces: [String] {
        didSet { UserDefaults.standard.setValue(favoriteWorkspaces, forKey: ExperimentalUISettingsItems.favoriteWorkspaces.rawValue) }
    }

    /// The strips of the menu bar item group the workspaces by monitor; the pills draw a bay around each group (with
    /// more than one monitor)
    var groupsWorkspacesByMonitor: Bool {
        didSet { UserDefaults.standard.setValue(groupsWorkspacesByMonitor, forKey: ExperimentalUISettingsItems.groupsWorkspacesByMonitor.rawValue) }
    }

    /// A click on a workspace in the row of the menu bar item focuses it (see ``MenuBarClicks``). Off: every click opens
    /// the panel
    var switchesWorkspaceOnClick: Bool {
        didSet { UserDefaults.standard.setValue(switchesWorkspaceOnClick, forKey: ExperimentalUISettingsItems.switchesWorkspaceOnClick.rawValue) }
    }

    init(_ defaults: UserDefaults = .standard) {
        displayStyle = defaults.string(forKey: ExperimentalUISettingsItems.displayStyle.rawValue).flatMap(MenuBarStyle.init(rawValue:)) ?? .monospacedText
        favoriteWorkspaces = defaults.stringArray(forKey: ExperimentalUISettingsItems.favoriteWorkspaces.rawValue) ?? []
        switchesWorkspaceOnClick = defaults.object(forKey: ExperimentalUISettingsItems.switchesWorkspaceOnClick.rawValue) as? Bool ?? true
        groupsWorkspacesByMonitor = defaults.bool(forKey: ExperimentalUISettingsItems.groupsWorkspacesByMonitor.rawValue)
    }
}

/// The style of the menu bar item. Saved by its raw value: an unknown one is the default style
enum MenuBarStyle: String, CaseIterable, Identifiable, Equatable, Hashable {
    case monospacedText
    case systemText
    case pills
    case dots
    case panes
    case skyline
    case shelf
    case matrix
    case heft
    case workspaceApps
    case squares
    case i3
    case i3Ordered
    var id: String { rawValue }
    var title: String {
        switch self {
            case .monospacedText: "Monospaced font"
            case .systemText: "System font"
            case .pills: "Pills"
            case .dots: "Dots"
            case .panes: "Panes"
            case .skyline: "Skyline"
            case .shelf: "Shelf"
            case .matrix: "Matrix"
            case .heft: "Heft"
            case .workspaceApps: "Workspace and apps"
            case .squares: "Square images"
            case .i3: "i3 style grouped"
            case .i3Ordered: "i3 style ordered"
        }
    }
    /// How the style shows the number of windows of a workspace: a window that comes or goes is animated only if it
    /// changes the bucket. nil: the style doesn't show it
    func windowCountBucket(_ count: Int) -> Int? {
        switch self {
            case .panes, .skyline: min(count, 4)
            case .heft: count == 0 ? 0 : count < 3 ? 1 : 2
            case .matrix: count < 2 ? count : count < 4 ? 2 : 3
            case .monospacedText, .systemText, .pills, .dots, .shelf, .workspaceApps, .squares, .i3, .i3Ordered: nil
        }
    }

    /// Shows a row of workspaces: the favorites choose them, and a click on one focuses it
    var showsStrip: Bool {
        switch self {
            case .pills, .dots, .panes, .skyline, .shelf, .matrix, .heft, .i3, .i3Ordered: true
            case .monospacedText, .systemText, .workspaceApps, .squares: false
        }
    }
    var explanation: String {
        switch self {
            case .monospacedText, .systemText: "The workspace that each monitor shows, as text"
            case .pills: "The workspaces with windows, the focused one filled, one shown on another monitor outlined"
            case .dots: "A dot for each workspace with windows, the focused one with its name"
            case .panes: "Each workspace as a small screen, split into its windows"
            case .skyline: "A bar for each workspace, as high as it has windows"
            case .shelf: "Each workspace as the icon of its app, the focused one with its apps"
            case .matrix: "Ten workspaces in two rows, a mark as big as it has windows"
            case .heft: "The names, as heavy as their workspaces are full"
            case .workspaceApps: "The focused workspace and its apps"
            case .squares: "The workspace that each monitor shows, the focused one filled"
            case .i3: "The workspaces that the monitors show, then the other ones with windows"
            case .i3Ordered: "All workspaces with windows, in order"
        }
    }
}

enum ExperimentalUISettingsItems: String {
    case displayStyle
    case favoriteWorkspaces
    case switchesWorkspaceOnClick
    case groupsWorkspacesByMonitor
}
