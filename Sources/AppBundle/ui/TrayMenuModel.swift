import AppKit
import Common

public final class TrayMenuModel: ObservableObject {
    @MainActor public static let shared = TrayMenuModel()

    private init() {}

    @Published var trayText: String = ""
    @Published var trayItems: [TrayItem] = []
    /// Is "layouting" enabled
    @Published var isEnabled: Bool = true
    @Published var workspaces: [WorkspaceViewModel] = []
    @Published var experimentalUISettings: ExperimentalUISettings = ExperimentalUISettings()
    @Published var settingsHaveProblems: Bool = false
    @Published var axPermissionStatus: AxPermissionStatus = .waitingWithPrompt

    /// What the menu bar item shows
    @MainActor var menuBarState: MenuBarState {
        MenuBarState(
            style: experimentalUISettings.displayStyle,
            trayText: trayText,
            trayItems: trayItems,
            workspaces: workspaces,
            settingsHaveProblems: settingsHaveProblems,
        )
    }

    /// Another style for the menu bar item: the old style fades into the new one
    @MainActor func setMenuBarStyle(_ style: MenuBarStyle) {
        let before = menuBarState
        experimentalUISettings.displayStyle = style
        MenuBarAnimator.shared.stateDidChange(from: before, to: menuBarState)
    }
}

enum AxPermissionStatus: Equatable {
    case granted
    case waiting
    case waitingWithPrompt
}

@MainActor func updateTrayText() {
    let sortedMonitors = globalSortedMonitorInfos
    let focus = globalFocus
    let model = TrayMenuModel.shared
    let before = model.menuBarState
    model.update(\.trayText, (activeMode?.takeIf { $0 != mainModeId }?.first.map { "(\($0.uppercased())) " } ?? "") +
        sortedMonitors
        .lazy
        .map {
            let hasFullscreenWindows = $0.visibleWorkspace.allLeafWindowsRecursive.contains { $0.isFullscreen }
            let visibleWorkspaceName = hasFullscreenWindows ? "[\($0.visibleWorkspace.name)]" : $0.visibleWorkspace.name
            return ($0.visibleWorkspace == focus.workspace && sortedMonitors.count > 1 ? "*" : "") + visibleWorkspaceName
        }
        .joined(separator: " │ "))
    let isMultiMonitor = sortedMonitors.count > 1
    model.update(\.workspaces, Workspace.all.map {
        let windows = $0.allLeafWindowsRecursive
        let apps = windows.map { $0.app.name?.takeIf { !$0.isEmpty } }.filterNotNil().toSet()
        let dash = " - "
        let suffix = switch true {
            case !apps.isEmpty: dash + apps.sorted().joinTruncating(separator: ", ", length: 25)
            case $0.isVisible: dash + $0.workspaceMonitorInfo.name
            default: ""
        }
        var appBundleUrls: [URL] = []
        for window in windows {
            guard appBundleUrls.count < 4, let url = (window.app as? MacApp)?.bundleUrl, !appBundleUrls.contains(url) else { continue }
            appBundleUrls.append(url)
        }
        return WorkspaceViewModel(
            name: $0.name,
            suffix: suffix,
            appBundleUrls: appBundleUrls,
            windowCount: windows.count { $0.lifeStatus.isInhabited },
            monitorName: isMultiMonitor && $0.isVisible ? $0.workspaceMonitorInfo.name : nil,
            isFocused: focus.workspace == $0,
            isEffectivelyEmpty: $0.isEffectivelyEmpty,
            isVisible: $0.isVisible,
            hasFullscreenWindows: windows.contains { $0.isFullscreen },
        )
    })
    var items = sortedMonitors.map {
        let hasFullscreenWindows = $0.visibleWorkspace.allLeafWindowsRecursive.contains { $0.isFullscreen }
        return TrayItem(
            type: .workspace,
            name: $0.visibleWorkspace.name,
            isActive: $0.visibleWorkspace == focus.workspace,
            hasFullscreenWindows: hasFullscreenWindows,
        )
    }
    let mode = activeMode?.takeIf { $0 != mainModeId }?.first.map {
        TrayItem(type: .mode, name: $0.uppercased(), isActive: true, hasFullscreenWindows: false)
    }
    if let mode {
        items.insert(mode, at: 0)
    }
    model.update(\.trayItems, items)
    MenuBarAnimator.shared.stateDidChange(from: before, to: model.menuBarState)
}

extension TrayMenuModel {
    /// Assigning an equal value to a @Published property still emits objectWillChange, which re-renders the menu bar.
    /// updateTrayText runs at the end of every refresh session, so redundant assignments are skipped
    fileprivate func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<TrayMenuModel, T>, _ newValue: T) {
        if self[keyPath: keyPath] != newValue {
            self[keyPath: keyPath] = newValue
        }
    }
}

struct WorkspaceViewModel: Hashable {
    let name: String
    let suffix: String
    /// Up to 4 apps of the workspace (for the icons in the menu)
    let appBundleUrls: [URL]
    let windowCount: Int
    /// The monitor that shows the workspace, when there is more than one monitor
    let monitorName: String?
    let isFocused: Bool
    let isEffectivelyEmpty: Bool
    let isVisible: Bool
    let hasFullscreenWindows: Bool

    /// The menu bar panel and the strips of the menu bar item (pills, dots) leave out the workspaces that are empty and
    /// not shown: the persistent ones are just noise there
    var isListed: Bool { !isEffectivelyEmpty || isVisible || isFocused }
}

enum TrayItemType: String, Hashable {
    case mode
    case workspace
}

private let validLetters = "A" ... "Z"

struct TrayItem: Hashable, Identifiable {
    let type: TrayItemType
    let name: String
    let isActive: Bool
    let hasFullscreenWindows: Bool
    var systemImageName: String? {
        // System image type is only valid for numbers 0 to 50 and single capital char workspace name
        switch Int(name) {
            case let number?: if !(0 ... 50).contains(number) { return nil }
            case nil where name.count == 1: if !validLetters.contains(name) { return nil }
            default: return nil
        }
        let lowercasedName = name.lowercased()
        return switch type {
            case .mode: "\(lowercasedName).circle"
            case .workspace where isActive: "\(lowercasedName).square.fill"
            case .workspace: "\(lowercasedName).square"
        }
    }
    var id: String {
        return type.rawValue + name
    }
}
