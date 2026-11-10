import Common
import Foundation

/// Brings settings of an older MarSpace (and imported configs) to the current schema
@MainActor
enum SettingsMigration {
    static func migrate(_ settings: inout Settings) {
        if settings.schemaVersion < 2 { foldWorkspaceShortcuts(&settings) }
        settings.schemaVersion = Settings.currentSchemaVersion
    }

    /// The shortcuts of the main mode that go to (or move the window to) a persistent workspace with the key of its name,
    /// all with the same modifiers, become ``Settings/workspaceShortcuts``. The key is matched by its name in the keyboard
    /// preset that they were written with (`ctrl-alt-z` for workspace Z), not by the keyboard layout of macOS
    static func foldWorkspaceShortcuts(_ settings: inout Settings) {
        guard let main = settings.modes.firstIndex(where: { $0.name == mainModeId }) else { return }
        let keyNames = KeyNames.of(settings.general.keyboardLayout)
        let persistent = Set(settings.workspaces.persistent)
        func fold(_ workspace: (Action) -> String?) -> KeyChord.Modifiers? {
            let shortcuts = settings.modes[main].shortcuts
            let folded = shortcuts.indices.filter { index in
                let shortcut = shortcuts[index]
                guard shortcut.actions.count == 1, let name = workspace(shortcut.actions[0]), name.count == 1, persistent.contains(name)
                else { return false }
                return keyNames.name(shortcut.chord.key) == name.lowercased()
            }
            let modifiers = Set(folded.map { shortcuts[$0].chord.modifiers })
            guard modifiers.count == 1, let only = modifiers.first, !only.isEmpty else { return nil }
            settings.modes[main].shortcuts.remove(atOffsets: IndexSet(folded))
            return only
        }
        settings.workspaceShortcuts.goTo = fold { if case .workspace(let name) = $0 { name } else { nil } }
        settings.workspaceShortcuts.moveWindowTo = fold { if case .moveWindowToWorkspace(let name) = $0 { name } else { nil } }
    }
}
