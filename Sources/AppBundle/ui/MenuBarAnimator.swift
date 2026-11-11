import AppKit
import Common
import SwiftUI

/// Everything the menu bar item shows. The item is drawn from it alone (``MenuBarItemContent``), so the state before a
/// change is all it takes to animate the change
struct MenuBarState: Equatable {
    var style: MenuBarStyle
    var trayText: String
    var trayItems: [TrayItem]
    var workspaces: [WorkspaceViewModel]
    var settingsHaveProblems: Bool
    /// See ``ExperimentalUISettings/favoriteWorkspaces``
    var favorites: [String] = []
    /// See ``ExperimentalUISettings/groupsWorkspacesByMonitor``
    var groupsByMonitor: Bool = false

    var focusedWorkspace: WorkspaceViewModel? { workspaces.first(where: \.isFocused) }
    var mode: TrayItem? { trayItems.first { $0.type == .mode } }

    /// The workspaces that the strips (pills, dots, i3, …) show: the favorite ones in the order of the user, also when
    /// they are empty, then the other ones that the monitors show. The favorites stay where they are, under the mouse.
    /// Without favorites, all workspaces with windows, in the order of the workspaces
    /// Grouped by monitor, if asked for
    var strip: [WorkspaceViewModel] {
        let strip = favorites.isEmpty
            ? workspaces.filter(\.isListed)
            : favorites.compactMap { name in workspaces.first { $0.name == name } } + workspaces.filter { $0.isVisible && !favorites.contains($0.name) }
        guard groupsByMonitor else { return strip }
        return strip.enumerated().sorted { ($0.element.monitorIndex, $0.offset) < ($1.element.monitorIndex, $1.offset) }.map(\.element)
    }

    func isInStrip(_ workspace: WorkspaceViewModel) -> Bool {
        favorites.isEmpty ? workspace.isListed : workspace.isVisible || favorites.contains(workspace.name)
    }

    /// A change of the focused workspace, of the shown or listed workspaces, of the binding mode or of the style is
    /// animated. Not a new app icon: the item just shows it. Compared at the end of every refresh session, without
    /// allocations
    func looksAnimatedTheSame(as other: MenuBarState) -> Bool {
        style == other.style && trayText == other.trayText && mode == other.mode && favorites == other.favorites &&
            groupsByMonitor == other.groupsByMonitor &&
            workspaces.elementsEqual(other.workspaces) {
                $0.name == $1.name && $0.isFocused == $1.isFocused && $0.isVisible == $1.isVisible &&
                    $0.isEffectivelyEmpty == $1.isEffectivelyEmpty &&
                    style.windowCountBucket($0.windowCount) == style.windowCountBucket($1.windowCount) &&
                    $0.monitorIndex == $1.monitorIndex
            }
    }
}

/// The menu bar item on its way from one state to the next
struct MenuBarTransition: Equatable {
    let from: MenuBarState
    /// From 0 to 1, linear in time
    var progress: Double
    /// Reduce Motion (accessibility): the old state fades into the new one, nothing moves
    let reduceMotion: Bool
}

/// Animates the menu bar item when the focused workspace (or the style, or the binding mode) changes. Nothing runs
/// between changes: no timer, and the item is drawn once per change. During a change, the item is drawn once per frame,
/// for ``duration``
@MainActor
final class MenuBarAnimator: ObservableObject {
    static let shared = MenuBarAnimator()

    private init() {}

    /// nil while nothing moves
    @Published private(set) var transition: MenuBarTransition? = nil
    private var animation: Task<Void, Never>? = nil

    private static let duration: Duration = .milliseconds(320)
    private static let frameInterval: Duration = .milliseconds(16)

    func stateDidChange(from before: MenuBarState, to after: MenuBarState) {
        if before.looksAnimatedTheSame(as: after) { return }
        // A change during a change starts from where the previous one was going: the old state is the state it was going
        // to, not what was on the screen
        animation?.cancel()
        transition = MenuBarTransition(
            from: before,
            progress: 0,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        )
        let start = ContinuousClock.now
        animation = Task.startUnstructured {
            while true {
                try? await Task.sleep(for: Self.frameInterval)
                if Task.isCancelled { return }
                let progress = (ContinuousClock.now - start) / Self.duration
                if progress >= 1 {
                    self.transition = nil
                    return
                }
                self.transition?.progress = progress
            }
        }
    }
}
