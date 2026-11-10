import AppKit
import Common

struct ModeCommand: Command {
    let args: ModeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let mode = args.targetMode.val
        // A mode that doesn't exist has no bindings: every shortcut would be off, also the one that leaves the mode
        guard config.modes[mode] != nil else {
            return .fail(io.err("The '\(mode)' mode doesn't exist. The modes: \(config.modes.keys.sorted().joined(separator: ", "))"))
        }
        await activateMode_nonCancellable(mode)
        return .succ
    }
}
