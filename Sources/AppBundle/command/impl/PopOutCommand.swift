import AppKit
import Common

/// Pops the window out of the layout and back in (Omarchy's "pop window out"), see ``Window/popOut(on:)``
struct PopOutCommand: Command {
    let args: PopOutCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }
        guard let window = target.windowOrNil else { return .fail(io.err(noWindowIsFocused)) }
        if !window.isPoppedOut { window.poppedOut = nil } // Tiled or unpinned meanwhile: what it was is outdated
        let popsOut = switch args.toggle {
            case .on: true
            case .off: false
            case .toggle: !window.isPoppedOut
        }
        if popsOut == window.isPoppedOut { return .succ } // Already
        switch window.windowParentCases {
            case .tilingContainer, .floatingWindowsContainer: break
            case .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer, .macosMinimizedWindowsContainer,
                 .macosPopupWindowsContainer, nil:
                return .fail(io.err("Can't pop out a window in macOS fullscreen, a minimized window or a window of a hidden app"))
        }
        if popsOut {
            window.popOut(on: target.workspace)
        } else {
            do {
                try await window.popIn(on: target.workspace)
            } catch {
                return .fail(io.err(bugPrompt()))
            }
        }
        return .succ
    }
}
