import AppKit
import Common

struct TrueCommand: Command {
    let args: TrueCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache: Bool = false
    /*conforms*/ let isReadOnly = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> ConditionalExitCode { ._true }
}
