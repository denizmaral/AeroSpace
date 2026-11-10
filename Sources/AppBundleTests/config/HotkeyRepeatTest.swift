@testable import AppBundle
import Common
import HotKey
import Testing

/// A shortcut can repeat while its keys are held (Hyprland's `binde`): resizing in steps is what it's for
@MainActor
@Suite(.serializedGlobally)
struct HotkeyRepeatTest {
    init() { setUpWorkspacesForTests() }

    @Test func testRepeatsUntilTheKeysAreReleased() async throws {
        var checks = 0
        var runs = 0
        try await repeatWhileHeld(delay: .milliseconds(1), interval: .milliseconds(1), isHeld: { checks += 1; return checks <= 3 }, action: { runs += 1 })
        assertEquals(runs, 3)
    }

    /// The release of the hotkey cancels the repeat: also before the first repetition
    @Test func testAShortPressDoesntRepeat() async {
        var runs = 0
        let task = Task.startUnstructured { @MainActor in
            try await repeatWhileHeld(delay: .seconds(60), interval: .milliseconds(1), isHeld: { true }, action: { runs += 1 })
        }
        await Task.yield()
        task.cancel()
        _ = await task.result
        assertEquals(runs, 0)
    }

    @Test func testCanceledBetweenTheRepetitions() async {
        var runs = 0
        var task: Task<(), any Error>? = nil
        task = Task.startUnstructured { @MainActor in
            try await repeatWhileHeld(delay: .milliseconds(1), interval: .milliseconds(1), isHeld: { true }, action: {
                runs += 1
                if runs == 2 { task?.cancel() } // Released during the second run: it's finished, nothing follows
            })
        }
        _ = await task?.result
        assertEquals(runs, 2)
    }

    /// Shortcuts that make the window bigger or smaller repeat, unless the user says otherwise. The others don't, unless
    /// the user says so
    @Test func testWhichShortcutsRepeat() {
        func shortcut(_ actions: [Action], repeats: Bool? = nil) -> Settings.Shortcut {
            Settings.Shortcut(chord: KeyChord([.control, .option], .f1), actions: IdentifiedList(actions), repeatsWhileHeld: repeats)
        }
        assertEquals(shortcut([.resize(.smart, .add(50))]).repeats, true)
        assertEquals(shortcut([.resize(.width, .subtract(50))]).repeats, true)
        assertEquals(shortcut([.resize(.width, .set(800))]).repeats, false) // The same size again
        assertEquals(shortcut([.resize(.smart, .add(50)), .enterMode(mainModeId)]).repeats, false)
        assertEquals(shortcut([.focus(.left)]).repeats, false)
        assertEquals(shortcut([]).repeats, false)
        assertEquals(shortcut([.resize(.smart, .add(50))], repeats: false).repeats, false)
        assertEquals(shortcut([.focus(.left)], repeats: true).repeats, true)
    }

    @Test func testTheBindingKnowsThatItRepeats() {
        var settings = Settings()
        settings.workspaceShortcuts = .init(goTo: nil, moveWindowTo: nil)
        settings.modes = [Settings.BindingMode(name: mainModeId, shortcuts: [
            Settings.Shortcut(chord: KeyChord([.option], .equal), actions: [.resize(.smart, .add(50))]),
            Settings.Shortcut(chord: KeyChord([.option], .h), actions: [.focus(.left)]),
        ])]
        let bindings = settings.compile().config.modes[mainModeId]?.bindings
        assertEquals(bindings?["alt-equal"]?.repeatsWhileHeld, true)
        assertEquals(bindings?["alt-h"]?.repeatsWhileHeld, false)
    }
}
