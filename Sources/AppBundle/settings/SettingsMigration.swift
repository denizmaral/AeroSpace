import Common
import Foundation
import HotKey

/// Brings settings of an older MarSpace (and imported configs) to the current schema
@MainActor
enum SettingsMigration {
    static func migrate(_ settings: inout Settings) {
        if settings.schemaVersion < 2 { foldWorkspaceShortcuts(&settings) }
        if settings.schemaVersion < 3 { enterFullscreenInWindowRules(&settings) }
        settings.schemaVersion = Settings.currentSchemaVersion
    }

    /// The shortcuts of the main mode that go to (or move the window to) a persistent workspace with the key of its name,
    /// all with the same modifiers, become ``Settings/workspaceShortcuts``. The key is matched by its name in the keyboard
    /// preset that they were written with (`ctrl-alt-z` for workspace Z), not by the keyboard layout of macOS.
    ///
    /// A fold is kept only if every shortcut still runs the same commands and no problem appears: e.g. not if an explicit
    /// shortcut would take a generated one, or if going to and moving to had the same modifiers. A workspace that had no
    /// shortcut may get one
    static func foldWorkspaceShortcuts(_ settings: inout Settings) {
        guard let main = settings.modes.firstIndex(where: { $0.name == mainModeId }) else { return }
        let keyNames = KeyNames.of(settings.general.keyboardLayout)
        let persistent = Set(settings.workspaces.persistent)
        func fold(_ settings: inout Settings, _ workspace: (Action) -> String?) -> KeyChord.Modifiers? {
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
        func folded(goTo: Bool, moveWindowTo: Bool) -> Settings {
            var result = settings
            if goTo { result.workspaceShortcuts.goTo = fold(&result) { if case .workspace(let name) = $0 { name } else { nil } } }
            if moveWindowTo {
                result.workspaceShortcuts.moveWindowTo = fold(&result) { if case .moveWindowToWorkspace(let name) = $0 { name } else { nil } }
            }
            return result
        }
        let presetKeys = getKeysPreset(settings.general.keyboardLayout)
        let keyOfName: @MainActor (String) -> Key? = { presetKeys[$0.lowercased()] }
        let before = settings.compile(keyForCharacter: keyOfName)
        let oldBindings = before.config.modes[mainModeId]?.bindings ?? [:]
        for candidate in [folded(goTo: true, moveWindowTo: true), folded(goTo: true, moveWindowTo: false), folded(goTo: false, moveWindowTo: true)] {
            let after = candidate.compile(keyForCharacter: keyOfName)
            let newBindings = after.config.modes[mainModeId]?.bindings ?? [:]
            if after.problems.count <= before.problems.count, oldBindings.allSatisfy({ newBindings[$0.key] == $0.value }) {
                settings = candidate
                return
            }
        }
    }

    /// A window rule that toggled the fullscreen enters it now. A rule runs again for a window that is detected again (e.g.
    /// after a restart): a toggle took a fullscreen window out of its fullscreen
    static func enterFullscreenInWindowRules(_ settings: inout Settings) {
        for rule in settings.windowRules.indices {
            for index in settings.windowRules[rule].actions.indices {
                if case .fullscreen(let kind) = settings.windowRules[rule].actions[index] {
                    settings.windowRules[rule].actions[index] = .enterFullscreen(kind)
                }
            }
        }
    }
}
