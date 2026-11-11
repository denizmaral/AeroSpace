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

    /// A click on a workspace in the row of the menu bar item focuses it (see ``MenuBarClicks``). Off: every click opens
    /// the panel
    var switchesWorkspaceOnClick: Bool {
        didSet { UserDefaults.standard.setValue(switchesWorkspaceOnClick, forKey: ExperimentalUISettingsItems.switchesWorkspaceOnClick.rawValue) }
    }

    init(_ defaults: UserDefaults = .standard) {
        displayStyle = defaults.string(forKey: ExperimentalUISettingsItems.displayStyle.rawValue).flatMap(MenuBarStyle.init(rawValue:)) ?? .monospacedText
        favoriteWorkspaces = defaults.stringArray(forKey: ExperimentalUISettingsItems.favoriteWorkspaces.rawValue) ?? []
        switchesWorkspaceOnClick = defaults.object(forKey: ExperimentalUISettingsItems.switchesWorkspaceOnClick.rawValue) as? Bool ?? true
    }
}

/// The style of the menu bar item. Saved by its raw value: an unknown one is the default style
enum MenuBarStyle: String, CaseIterable, Identifiable, Equatable, Hashable {
    case monospacedText
    case systemText
    case pills
    case dots
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
            case .workspaceApps: "Workspace and apps"
            case .squares: "Square images"
            case .i3: "i3 style grouped"
            case .i3Ordered: "i3 style ordered"
        }
    }
    /// Shows a row of workspaces: the favorites choose them, and a click on one focuses it
    var showsStrip: Bool {
        switch self {
            case .pills, .dots, .i3, .i3Ordered: true
            case .monospacedText, .systemText, .workspaceApps, .squares: false
        }
    }
    var explanation: String {
        switch self {
            case .monospacedText, .systemText: "The workspace that each monitor shows, as text"
            case .pills: "The workspaces with windows, the focused one filled, one shown on another monitor outlined"
            case .dots: "A dot for each workspace with windows, the focused one with its name"
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
}
