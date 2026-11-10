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

    private let qwerty: @MainActor (String) -> Key? = { keyNotationToKeyCode[$0.lowercased()] }

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
}
