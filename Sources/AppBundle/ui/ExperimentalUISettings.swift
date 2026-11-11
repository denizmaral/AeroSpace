import SwiftUI

struct ExperimentalUISettings {
    var displayStyle: MenuBarStyle {
        get {
            switch UserDefaults.standard.string(forKey: ExperimentalUISettingsItems.displayStyle.rawValue) {
                case let value?: MenuBarStyle(rawValue: value) ?? .monospacedText
                case nil: .monospacedText
            }
        }
        set {
            UserDefaults.standard.setValue(newValue.rawValue, forKey: ExperimentalUISettingsItems.displayStyle.rawValue)
            UserDefaults.standard.synchronize()
        }
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
}
