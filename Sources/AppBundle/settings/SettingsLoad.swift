import AppKit
import Common

/// The settings to use, and what the user should know about them (shown in a message).
///
/// The first launch takes over the AeroSpace TOML config once (or the bundled default config): from then on, the
/// settings are the only source. A damaged settings file is replaced by the backup; settings that can't be read at all
/// are not overwritten, the default settings are used meanwhile
@MainActor
func loadSettings(store: SettingsStore = .applicationSupport) -> (settings: Settings, notices: [String]) {
    switch store.load() {
        case .loaded(var settings):
            if settings.schemaVersion < Settings.currentSchemaVersion {
                SettingsMigration.migrate(&settings)
                try? store.save(settings)
            }
            return (settings, [])
        case .restoredFromBackup(let settings, let damaged):
            return (settings, ["The settings were damaged, the last good settings were restored. The damaged file is kept at \(damaged.path)"])
        case .unreadable(let reason):
            return (defaultSettings(), ["\(reason). The default settings are used meanwhile, the settings file was not changed."])
        case .none:
            let url = if case .file(let url) = findCustomConfigUrl() { url } else { defaultConfigUrl }
            let imported = SettingsImport.settings(fromToml: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
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

/// Saves and applies the settings edited in the settings window (they compile without problems)
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
    let (newConfig, problems) = settings.compile()
    guard problems.isEmpty else { return }
    await applyConfig_nonCancellable(newConfig)
    scheduleCancellableCompleteRefreshSession(.settingsChanged) // Gaps, border, layout
}
