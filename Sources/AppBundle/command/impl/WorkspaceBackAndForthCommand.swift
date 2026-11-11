import AppKit
import Common

struct WorkspaceBackAndForthCommand: Command {
    let args: WorkspaceBackAndForthCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        // E.g. right after the start of MarSpace
        guard let prevFocusedWorkspace else { return .fail(io.err("There is no previous workspace yet")) }
        return .from(bool: prevFocusedWorkspace.focusWorkspace())
    }
}
