import AppKit
import Common

struct PinCommand: Command {
    let args: PinCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else {
            return .fail(io.err(noWindowIsFocused))
        }
        let newState: Bool = switch args.toggle {
            case .on: true
            case .off: false
            case .toggle: !window.isPinned
        }
        // A tiling window has its place in the layout of one workspace
        if newState, !window.isFloating {
            return .fail(io.err("Only a floating window can be pinned. 'layout floating' makes the window floating"))
        }
        window.isPinned = newState
        // It goes with the monitor from workspace to workspace: it floats on its own account (see WorkspaceLayout.floating)
        if newState { window.stopFloatingByWorkspaceLayout() }
        return .succ
    }
}

extension Workspace {
    /// A pinned window is on the workspace that its monitor shows, whichever it is (Hyprland's `pin`): when another
    /// workspace is shown, the pinned windows of the previous one go there, before the layout hides the rest of it.
    /// They don't take the focus of the workspace that they come to
    @MainActor
    static func movePinnedWindowsToVisibleWorkspaces() {
        for workspace in Workspace.all where !workspace.isVisible {
            let pinned = workspace.floatingWindows.filter(\.isPinned)
            if pinned.isEmpty { continue }
            let visible = workspace.workspaceMonitorInfo.visibleWorkspace
            let mostRecent = visible.mostRecentWindowRecursive
            for window in pinned {
                // The user didn't move it: it keeps its place in the tree of its workspace (a popped out window goes back
                // to it, if it's popped back in there, see TilingSlot)
                let tilingSlot = window.tilingSlot
                window.bindAsFloatingWindow(to: visible)
                window.tilingSlot = tilingSlot
            }
            mostRecent?.markAsMostRecentChild()
        }
    }
}
