import AppKit
import Common

/// `layout tiling` for every floating window of the workspace: e.g. after windows were made floating by mistake
struct TileFloatingWindowsCommand: Command {
    let args: TileFloatingWindowsCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        let workspace = target.workspace
        for window in workspace.floatingWindows {
            do {
                try await window.tileFloatingWindow(on: workspace)
            } catch {
                return .fail(io.err(bugPrompt()))
            }
        }
        return .succ
    }
}
