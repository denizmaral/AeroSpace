import AppKit
import Common

/// The settings on the disk, and what the user should know about them (shown in a message). The first launch starts with
/// ``Settings/defaults``. A damaged settings file is replaced by the backup; settings that can't be read at all are not
/// overwritten, the defaults are used meanwhile. `dryRun`: nothing is written
@MainActor
func loadSettings(store: SettingsRepository = .applicationSupport, dryRun: Bool = false) -> (settings: Settings, notices: [String]) {
    switch store.load(repair: !dryRun) {
        case .loaded(let settings):
            return (settings, [])
        case .restoredFromBackup(let settings, let damaged):
            return (settings, ["The settings were damaged, the last good settings were restored. The damaged file is kept at \(damaged.path)"])
        case .unreadable(let reason):
            return (.defaults, ["\(reason). The default settings are used meanwhile. The file is never overwritten: a change in the settings keeps it aside."])
        case .none:
            if !dryRun {
                do {
                    try store.save(.defaults)
                } catch {
                    return (.defaults, ["The settings can't be saved: \(error.localizedDescription)"])
                }
            }
            return (.defaults, [])
    }
}
