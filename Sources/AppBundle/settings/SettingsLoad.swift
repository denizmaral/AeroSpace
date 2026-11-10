import AppKit
import Common

/// The settings to use, and what the user should know about them (shown in a message).
///
/// The first launch takes over the AeroSpace TOML config once (or the bundled default config): from then on, the
/// settings are the only source. A damaged settings file is replaced by the backup; settings that can't be read at all
/// are not overwritten, the default settings are used meanwhile. `dryRun`: nothing is written
@MainActor
func loadSettings(store: SettingsStore = .applicationSupport, dryRun: Bool = false) -> (settings: Settings, notices: [String]) {
    switch store.load(repair: !dryRun) {
        case .loaded(var settings):
            if settings.schemaVersion < Settings.currentSchemaVersion {
                let version = settings.schemaVersion
                SettingsMigration.migrate(&settings)
                if !dryRun {
                    store.keepCopy(named: "Settings.schema-\(version).marspace") // For an older MarSpace
                    try? store.save(settings)
                }
            }
            return (settings, [])
        case .restoredFromBackup(let settings, let damaged):
            return (settings, ["The settings were damaged, the last good settings were restored. The damaged file is kept at \(damaged.path)"])
        case .unreadable(let reason):
            return (defaultSettings(), ["\(reason). The default settings are used meanwhile. The file is never overwritten: a change in the settings keeps it aside."])
        case .none:
            return switch findCustomConfigUrl() {
                case .file(let url): importSettings(from: url, store: store, dryRun: dryRun)
                case .ambiguousConfigError(let urls):
                    importSettings(from: urls[0], store: store, dryRun: dryRun, notes: [
                        "There are several AeroSpace configs: \(urls.map(\.path).joined(separator: ", ")). \(urls[0].path) was taken over.",
                    ])
                case .noCustomConfigExists: importSettings(from: defaultConfigUrl, store: store, dryRun: dryRun)
            }
    }
}

/// The first launch: the settings are taken over from an AeroSpace TOML config, once. A config that can't be read is not
/// taken over and nothing is saved: the next launch tries again (e.g. after it was fixed)
@MainActor
func importSettings(from url: URL, store: SettingsStore, dryRun: Bool, notes: [String] = []) -> (settings: Settings, notices: [String]) {
    guard let toml = try? String(contentsOf: url, encoding: .utf8), SettingsImport.isToml(toml) else {
        return (defaultSettings(), notes + [
            "\(url.path) can't be read as a TOML config. The default settings are used meanwhile. MarSpace takes the config over " +
                "at its next launch, unless the settings are changed before.",
        ])
    }
    let imported = SettingsImport.settings(fromToml: toml)
    if dryRun { return (imported.settings, notes) }
    do {
        try store.save(imported.settings)
    } catch {
        return (imported.settings, notes + ["The settings can't be saved: \(error.localizedDescription)"])
    }
    let problems = imported.problems.isEmpty ? [] : ["The settings were taken over from \(url.path) with these notes:"] + imported.problems
    return (imported.settings, notes + problems)
}

/// The bundled default config, as settings
@MainActor
func defaultSettings() -> Settings {
    SettingsImport.settings(fromToml: (try? String(contentsOf: defaultConfigUrl, encoding: .utf8)) ?? "").settings
}

/// Saves and applies the settings edited in the settings window. Invalid parts (reported as problems) are left out
@MainActor
func applySettings(_ settings: Settings) async {
    do {
        try SettingsStore.applicationSupport.save(settings)
    } catch {
        MessageModel.shared.message = Message(
            description: "\(aeroSpaceAppName) Settings",
            body: "The settings can't be saved: \(error.localizedDescription)",
        )
        return
    }
    await applyConfig_nonCancellable(settings.compile().config)
    scheduleCancellableCompleteRefreshSession(.settingsChanged) // Gaps, border, layout
}
