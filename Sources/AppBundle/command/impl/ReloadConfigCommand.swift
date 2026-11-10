import AppKit
import Common

struct ReloadConfigCommand: Command {
    let args: ReloadConfigCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let result = await reloadConfig_nonCancellable(args: args)
        if !result.stdout.isEmpty {
            io.out(result.stdout)
        }
        if !result.stderr.isEmpty {
            io.err(result.stderr)
        }
        return .from(bool: result.isOk)
    }
}

struct ReloadConfigResult {
    let isOk: Bool
    let stdout: String
    let stderr: String
}

/// Loads the settings and applies them
@MainActor func reloadConfig_nonCancellable(args: ReloadConfigCmdArgs = ReloadConfigCmdArgs(rawArgs: [])) async -> ReloadConfigResult {
    let loaded = loadSettings(dryRun: args.dryRun)
    let (newConfig, problems) = loaded.settings.compile()
    let errors = problems.map(\.description)
    if !args.noGui {
        let lines = loaded.notices + errors
        MessageModel.shared.message = lines.isEmpty
            ? nil
            : Message(description: "\(aeroSpaceAppName) Settings", body: lines.joined(separator: "\n\n"))
    }
    if !args.dryRun {
        TrayMenuModel.shared.settingsHaveProblems = !problems.isEmpty
        await applyConfig_nonCancellable(newConfig)
        configUrl = SettingsRepository.applicationSupport.fileUrl
    }
    return ReloadConfigResult(isOk: errors.isEmpty, stdout: errors.joined(separator: "\n\n"), stderr: loaded.notices.joined(separator: "\n\n"))
}

/// Applies a compiled config: shortcuts, login item, focus follows mouse. The next refresh session lays the windows out
@MainActor func applyConfig_nonCancellable(_ newConfig: Config) async {
    resetHotKeys()
    config = newConfig
    await activateMode_nonCancellable(activeMode)
    syncStartAtLogin()
    syncFocusFollowsMouse(config)
}
