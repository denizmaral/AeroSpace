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
    let loaded = await SettingsStore.shared.load(dryRun: args.dryRun)
    let errors = loaded.problems.map(\.description)
    if !args.noGui {
        let lines = loaded.notices + errors
        MessageModel.shared.message = lines.isEmpty
            ? nil
            : Message(description: "\(aeroSpaceAppName) Settings", body: lines.joined(separator: "\n\n"))
    }
    if !args.dryRun { configUrl = SettingsRepository.applicationSupport.fileUrl }
    return ReloadConfigResult(isOk: errors.isEmpty, stdout: errors.joined(separator: "\n\n"), stderr: loaded.notices.joined(separator: "\n\n"))
}

/// Applies a compiled config, by what changed (dev-docs/settings-architecture.md): the hotkeys of keys that no mode uses
/// anymore are removed and new ones registered (the others stay: their commands are looked up when they fire), the login
/// item changes only when "open at login" does. The next refresh session lays the windows out
@MainActor func applyConfig_nonCancellable(_ newConfig: Config) async {
    let oldConfig = config
    config = newConfig
    removeHotkeys(notIn: Set(newConfig.modes.values.flatMap(\.bindings.keys)))
    // The active mode may be gone (removed in the settings window): its shortcuts are, and the one that leaves it too
    await activateMode_nonCancellable(activeMode.map { newConfig.modes[$0] != nil ? $0 : mainModeId })
    if newConfig.startAtLogin != oldConfig.startAtLogin || !isLoginItemSynced {
        isLoginItemSynced = true
        syncStartAtLogin()
    }
    syncFocusFollowsMouse(config)
}

/// The login item is synced with the first config of the run (the settings may have changed while MarSpace wasn't running)
@MainActor private var isLoginItemSynced = false
