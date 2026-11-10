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
            let url = if case .file(let url) = findCustomConfigUrl() { url } else { defaultConfigUrl }
            let imported = SettingsImport.settings(fromToml: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
            if dryRun { return (imported.settings, []) }
            do {
                try store.save(imported.settings)
            } catch {
                return (imported.settings, ["The settings can't be saved: \(error.localizedDescription)"])
            }
            let notes = imported.problems.isEmpty ? [] : ["The settings were taken over from \(url.path) with these notes:"] + imported.problems
            return (imported.settings, notes)
    }
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
