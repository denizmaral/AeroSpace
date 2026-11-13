import AppKit
import Common

/// Switches the workspace between tiling, scrolling and floating (see ``WorkspaceLayout``), or cycles through layouts
struct WorkspaceLayoutCommand: Command {
    let args: WorkspaceLayoutCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let workspace = target.workspace
        let cycle = args.cycle.val
        let current = workspace.workspaceLayout
        // The layout after the current one, the first one if the current one isn't listed
        let next = cycle.firstIndex(of: current).map { cycle[($0 + 1) % cycle.count] } ?? cycle.first.orDie()
        if next == current {
            return args.failIfNoop
                ? .fail
                : .succ(io.err("The workspace is \(current.rawValue) already. Tip: use --fail-if-noop to exit with non-zero exit code"))
        }
        workspace.setWorkspaceLayout(next)
        if workspace.isVisible && !isUnitTest { WorkspaceLayoutHud.shared.show(next, of: workspace) }
        return .succ
    }
}
