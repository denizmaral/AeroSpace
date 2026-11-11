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
    /// See ``previewMenuBarStyle(_:)``. Never saved
    @Published private(set) var previewStyle: MenuBarStyle? = nil

    /// What the menu bar item shows
    @MainActor var menuBarState: MenuBarState {
        MenuBarState(
            style: previewStyle ?? experimentalUISettings.displayStyle,
            trayText: trayText,
            trayItems: trayItems,
            workspaces: workspaces,
            settingsHaveProblems: settingsHaveProblems,
            favorites: experimentalUISettings.favoriteWorkspaces,
            groupsByMonitor: experimentalUISettings.groupsWorkspacesByMonitor,
        )
    }

    /// Another style for the menu bar item: the old style fades into the new one
    @MainActor func setMenuBarStyle(_ style: MenuBarStyle) {
        let before = menuBarState
        experimentalUISettings.displayStyle = style
        MenuBarAnimator.shared.stateDidChange(from: before, to: menuBarState)
    }

    /// The menu bar item shows the style for a moment (the mouse is over it in the panel), without saving it. nil: the
    /// chosen style again
    @MainActor func previewMenuBarStyle(_ style: MenuBarStyle?) {
        if style == previewStyle { return }
        let before = menuBarState
        previewStyle = style
        MenuBarAnimator.shared.stateDidChange(from: before, to: menuBarState)
    }

    /// The workspace is shown in the strips of the menu bar item, or not any more: it comes in or shrinks away. A new
    /// favorite goes before the first one that comes after it in the order of the workspaces
    @MainActor func toggleFavorite(_ workspace: String) {
        var favorites = experimentalUISettings.favoriteWorkspaces
        if let index = favorites.firstIndex(of: workspace) {
            favorites.remove(at: index)
        } else {
            let key = workspace.toLogicalSegments()
            favorites.insert(workspace, at: favorites.firstIndex { key < $0.toLogicalSegments() } ?? favorites.endIndex)
        }
        setFavorites(favorites)
    }

    /// A workspace is dragged into the strip in the panel, or within it, before `other` (nil: at the end). Without
    /// favorites, the workspaces that the strip shows become the favorites, the dragged one joins them (see ``StripWell``)
    @MainActor func dropFavorite(_ workspace: String, before other: String?) {
        setFavorites(StripWell.favorites(dropping: workspace, before: other, in: favoritesOrStrip))
    }

    /// A workspace is dragged out of the strip in the panel
    @MainActor func removeFavorite(_ workspace: String) {
        setFavorites(StripWell.favorites(removing: workspace, from: favoritesOrStrip))
    }

    @MainActor private var favoritesOrStrip: [String] {
        let favorites = experimentalUISettings.favoriteWorkspaces
        return favorites.isEmpty ? menuBarState.strip.map(\.name) : favorites
    }

    @MainActor private func setFavorites(_ favorites: [String]) {
        if favorites == experimentalUISettings.favoriteWorkspaces { return }
        let before = menuBarState
        experimentalUISettings.favoriteWorkspaces = favorites
        MenuBarAnimator.shared.stateDidChange(from: before, to: menuBarState)
    }

    /// All workspaces with windows are shown in the strips of the menu bar item again
    /// The workspaces are grouped by monitor in the strips of the menu bar item, or not any more: they move to their places
    @MainActor func setGroupsWorkspacesByMonitor(_ value: Bool) {
        let before = menuBarState
        experimentalUISettings.groupsWorkspacesByMonitor = value
        MenuBarAnimator.shared.stateDidChange(from: before, to: menuBarState)
    }

    @MainActor func clearFavorites() {
        setFavorites([])
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
    var workspaces = Workspace.all.map {
        let windows = $0.allLeafWindowsRecursive
        let monitor = $0.workspaceMonitorInfo
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
            windows: ($0.rootTilingContainer.allLeafWindowsRecursive + $0.floatingWindowsContainer.children.filterIsInstance(of: Window.self))
                .filter(\.lifeStatus.isInhabited)
                .map { WindowSummary(windowId: $0.windowId, appBundleUrl: ($0.app as? MacApp)?.bundleUrl) },
            monitorIndex: sortedMonitors.firstIndex { $0.rect == monitor.rect } ?? 0,
        )
    }
    // An empty workspace is kept only if it's persistent: a favorite one is in the strips of the menu bar item anyway
    let favorites = model.experimentalUISettings.favoriteWorkspaces
    if favorites.contains(where: { name in !workspaces.contains { $0.name == name } }) {
        for name in favorites where !workspaces.contains(where: { $0.name == name }) {
            workspaces.append(WorkspaceViewModel(
                name: name,
                suffix: "",
                appBundleUrls: [],
                windowCount: 0,
                monitorName: nil,
                isFocused: false,
                isEffectivelyEmpty: true,
                isVisible: false,
                hasFullscreenWindows: false,
            ))
        }
        workspaces.sort { $0.name.toLogicalSegments() < $1.name.toLogicalSegments() }
    }
    model.update(\.workspaces, workspaces)
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
    /// Its windows in the order of the layout, the tiling ones first (the panel shows them as panes, and a window can be
    /// dragged to another workspace)
    var windows: [WindowSummary] = []
    /// Its monitor (the one that shows it, or would show it), in the order of the monitors
    var monitorIndex: Int = 0

    /// The menu bar panel and the strips of the menu bar item (pills, dots) leave out the workspaces that are empty and
    /// not shown: the persistent ones are just noise there
    var isListed: Bool { !isEffectivelyEmpty || isVisible || isFocused }
}

/// A window in the menu bar panel
struct WindowSummary: Hashable {
    let windowId: OpaqueWindowId
    let appBundleUrl: URL?
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
