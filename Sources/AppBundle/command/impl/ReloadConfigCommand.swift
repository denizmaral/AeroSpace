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

/// Loads the settings and applies them. `forceConfigUrl`: a TOML config instead, only for the check of the bundled
/// default config at startup
@MainActor func reloadConfig_nonCancellable(
    args: ReloadConfigCmdArgs = ReloadConfigCmdArgs(rawArgs: []),
    forceConfigUrl: URL? = nil,
) async -> ReloadConfigResult {
    if let forceConfigUrl { return await reloadTomlConfig_nonCancellable(args: args, url: forceConfigUrl) }
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
        TrayMenuModel.shared.lastReloadConfigContainedWarnings = false
        await applyConfig_nonCancellable(newConfig)
        configUrl = SettingsStore.applicationSupport.fileUrl
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
    syncConfigFileWatcher()
}

@MainActor private func reloadTomlConfig_nonCancellable(args: ReloadConfigCmdArgs, url: URL) async -> ReloadConfigResult {
    let result = readConfig(forceConfigUrl: url)
    let parseResult = result.parseConfigResult
    let warningsAsErrors = args.warningsAsErrors

    var errors = parseResult.errors.map { $0.description(.error) }
    var warnings = parseResult.warnings.map { $0.description(.warning) }
    let containsWarnings = !parseResult.warnings.isEmpty

    if !args.noGui {
        let lines = errors + warnings
        switch true {
            case !errors.isEmpty:
                let msg = failedToParseMsg(configUrl: result.configUrl, errorsCount: parseResult.errors.count, warningsCount: parseResult.warnings.count, lines: lines)
                MessageModel.shared.message = Message(body: msg)
            case warningsAsErrors && !warnings.isEmpty:
                let msg = parsedWithWarningsMsg(configUrl: result.configUrl, warningsCount: parseResult.warnings.count, lines: lines)
                MessageModel.shared.message = Message(body: msg)
            default:
                MessageModel.shared.message = nil
        }
    }
    if parseResult.allowReloadConfig && !args.dryRun {
        TrayMenuModel.shared.lastReloadConfigContainedWarnings = containsWarnings
        await applyConfig_nonCancellable(parseResult.config)
        configUrl = result.configUrl
    }

    if warningsAsErrors {
        errors += warnings
        warnings = []
    }

    return ReloadConfigResult(
        isOk: errors.isEmpty,
        stdout: errors.joined(separator: "\n\n"),
        stderr: warnings.joined(separator: "\n\n"),
    )
}

private func failedToParseMsg(configUrl: URL, errorsCount: Int, warningsCount: Int, lines: [String]) -> String {
    let path = configUrl.absoluteURL.path.singleQuoted
    let header = "Failed to parse \(path). \(errorsCount) error(s). \(warningsCount) warning(s)"
    return "\(header)\n\n\(lines.joined(separator: "\n\n"))"
}

private func parsedWithWarningsMsg(configUrl: URL, warningsCount: Int, lines: [String]) -> String {
    let path = configUrl.absoluteURL.path.singleQuoted
    let header = "Parsed \(path) with \(warningsCount) warning(s). Feel free to close this window."
    return "\(header)\n\n\(lines.joined(separator: "\n\n"))"
}
