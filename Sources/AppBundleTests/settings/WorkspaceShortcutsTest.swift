@testable import AppBundle
import Common
import Foundation
import HotKey
import Testing

/// Go to / move the window to every workspace whose name is one key: one set of modifiers each, the key of the name
@MainActor
@Suite(.serializedGlobally)
struct WorkspaceShortcutsTest {
    init() { setUpWorkspacesForTests() }

    private let qwerty: @MainActor (String) -> Key? = { getKeysPreset(.qwerty)[$0.lowercased()] }

    private func settings(_ persistent: [String]) -> Settings {
        var settings = Settings()
        settings.workspaces.persistent = persistent
        return settings
    }

    private func commands(_ config: Config, _ modifiers: KeyChord.Modifiers, _ key: Key) -> String? {
        config.modes[mainModeId]?.bindings.values
            .first { $0.modifiers == modifiers.eventFlags && $0.keyCode == key }?
            .commands.shellOfCommandsDescription
    }

    @Test func testShortcutsOfTheWorkspaces() {
        let (config, problems) = settings(["1", "T", "Mail"]).compile(keyForCharacter: qwerty)
        assertEquals(problems, [])
        assertEquals(commands(config, [.control, .option], .one), "workspace 1")
        assertEquals(commands(config, [.control, .option], .t), "workspace T")
        assertEquals(commands(config, [.control, .option, .shift], .t), "move-node-to-workspace T")
        assertEquals(config.modes[mainModeId]?.bindings.count, 4) // Mail has no key of its own
    }

    /// The key that types the name on the keyboard layout: on a Swiss German keyboard, Z is where a US keyboard has Y
    @Test func testKeyOfTheNameOnTheKeyboardLayout() {
        let swiss: @MainActor (String) -> Key? = { ["Z": .y, "Y": .z][$0] }
        let (config, _) = settings(["Z"]).compile(keyForCharacter: swiss)
        assertEquals(commands(config, [.control, .option], .y), "workspace Z")
    }

    @Test func testModifiersMustDifferAndNotBeEmpty() {
        var same = settings(["1"])
        same.workspaceShortcuts = .init(goTo: [.option], moveWindowTo: [.option])
        let (config, problems) = same.compile(keyForCharacter: qwerty)
        assertEquals(problems.map(\.location), ["Shortcuts › main › Workspaces"])
        assertEquals(commands(config, [.option], .one), "workspace 1") // Going there wins

        var empty = settings(["1"])
        empty.workspaceShortcuts = .init(goTo: [], moveWindowTo: nil)
        assertEquals(empty.compile(keyForCharacter: qwerty).problems.map(\.location), ["Shortcuts › main › Workspaces"])

        var off = settings(["1"])
        off.workspaceShortcuts = .init(goTo: nil, moveWindowTo: nil)
        assertEquals(off.compile(keyForCharacter: qwerty).config.modes[mainModeId]?.bindings.count, 0)
    }

    @Test func testShortcutThatIsAlsoTheShortcutOfAWorkspace() {
        var conflict = settings(["1"])
        conflict.modes = [Settings.BindingMode(name: mainModeId, shortcuts: [
            Settings.Shortcut(chord: KeyChord([.control, .option], .one), actions: [.focus(.left)]),
        ])]
        let (config, problems) = conflict.compile(keyForCharacter: qwerty)
        assertEquals(problems.map(\.message), ["It's also the shortcut of a workspace"])
        assertEquals(commands(config, [.control, .option], .one), "focus left") // The explicit shortcut wins
    }

    /// Settings of the first schema: the per-workspace shortcuts become the generated ones, the others stay
    @Test func testSettingsOfTheFirstSchemaAreMigrated() throws {
        let store = SettingsRepository(directory: FileManager.default.temporaryDirectory.appending(path: "WorkspaceShortcutsTest-\(UUID().uuidString)"))
        var old = settings(["1", "2"])
        old.schemaVersion = 1
        old.workspaceShortcuts = .init(goTo: nil, moveWindowTo: nil)
        old.modes = [Settings.BindingMode(name: mainModeId, shortcuts: [
            Settings.Shortcut(chord: KeyChord([.option], .one), actions: [.workspace("1")]),
            Settings.Shortcut(chord: KeyChord([.option], .two), actions: [.workspace("2")]),
            Settings.Shortcut(chord: KeyChord([.option, .shift], .one), actions: [.moveWindowToWorkspace("1")]),
            Settings.Shortcut(chord: KeyChord([.option], .h), actions: [.focus(.left)]),
        ])]
        try store.save(old)

        let migrated = loadSettings(store: store).settings
        assertEquals(migrated.schemaVersion, Settings.currentSchemaVersion)
        assertEquals(migrated.workspaceShortcuts, .init(goTo: [.option], moveWindowTo: [.option, .shift]))
        assertEquals(migrated.modes[0].shortcuts.map(\.actions), [[.focus(.left)]])
        assertEquals(store.load(), .loaded(migrated)) // Saved
    }

    /// A fold that would change what a shortcut does, or leave a lasting problem, isn't made
    @Test func testFoldsThatChangeAShortcutAreNotMade() {
        func migrated(_ persistent: [String], _ shortcuts: IdentifiedList<Settings.Shortcut>) -> Settings {
            var settings = settings(persistent)
            settings.schemaVersion = 1
            settings.workspaceShortcuts = .init(goTo: nil, moveWindowTo: nil)
            settings.modes = [Settings.BindingMode(name: mainModeId, shortcuts: shortcuts)]
            SettingsMigration.migrate(&settings)
            return settings
        }
        // Going to and moving to with the same modifiers: alt-2 would go to workspace 2 instead of moving the window there
        let same = migrated(["1", "2"], [
            Settings.Shortcut(chord: KeyChord([.option], .one), actions: [.workspace("1")]),
            Settings.Shortcut(chord: KeyChord([.option], .two), actions: [.moveWindowToWorkspace("2")]),
        ])
        assertEquals(same.workspaceShortcuts, .init(goTo: nil, moveWindowTo: nil))
        assertEquals(same.modes[0].shortcuts.count, 2)
        // alt-1 does more than going to workspace 1: the generated alt-1 would collide with it
        let more = migrated(["1", "2"], [
            Settings.Shortcut(chord: KeyChord([.option], .one), actions: [.workspace("1"), .moveMouse(.monitorLazyCenter)]),
            Settings.Shortcut(chord: KeyChord([.option], .two), actions: [.workspace("2")]),
        ])
        assertNil(more.workspaceShortcuts.goTo)
        assertEquals(more.compile(keyForCharacter: qwerty).problems, [])
        // Workspace H, and alt-h focuses: the generated alt-h would take it
        let h = migrated(["1", "H"], [
            Settings.Shortcut(chord: KeyChord([.option], .one), actions: [.workspace("1")]),
            Settings.Shortcut(chord: KeyChord([.option], .h), actions: [.focus(.left)]),
        ])
        assertNil(h.workspaceShortcuts.goTo)
        assertEquals(commands(h.compile(keyForCharacter: qwerty).config, [.option], .h), "focus left")
    }

    /// Different modifiers for the same kind of shortcut: they stay as they are
    @Test func testInconsistentShortcutsAreNotFolded() {
        var settings = settings(["1", "2"])
        settings.schemaVersion = 1
        settings.workspaceShortcuts = .init(goTo: nil, moveWindowTo: nil)
        settings.modes = [Settings.BindingMode(name: mainModeId, shortcuts: [
            Settings.Shortcut(chord: KeyChord([.option], .one), actions: [.workspace("1")]),
            Settings.Shortcut(chord: KeyChord([.control], .two), actions: [.workspace("2")]),
        ])]
        SettingsMigration.migrate(&settings)
        assertNil(settings.workspaceShortcuts.goTo)
        assertEquals(settings.modes[0].shortcuts.count, 2)
    }
}
