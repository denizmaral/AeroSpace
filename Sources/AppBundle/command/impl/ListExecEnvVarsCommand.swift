import AppKit
import Common

struct ListExecEnvVarsCommand: Command {
    let args: ListExecEnvVarsCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false
    /*conforms*/ let isReadOnly = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        for (key, value) in execEnvVariables {
            io.out("\(key)=\(value)")
        }
        return .succ
    }
}
