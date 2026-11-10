@testable import AppBundle
import Common
import Foundation
import Testing

/// The settings window saves and applies every edit shortly after the last one: nothing the user did is lost, the invalid
/// parts are left out
@MainActor
@Suite(.serializedGlobally)
struct SettingsModelTest {
    init() { setUpWorkspacesForTests() }

    private func settings() -> Settings {
        var settings = Settings()
        settings.modes = [Settings.BindingMode(name: "main", shortcuts: [Settings.Shortcut(chord: KeyChord([.option], .h), actions: [.focus(.left)])])]
        return settings
    }

    @Test func testValidEditsAreAppliedOnceAfterTheLastEdit() async throws {
        var applied: [Settings] = []
        let model = SettingsModel(settings: settings(), apply: { applied.append($0) })
        model.settings.appearance.gaps.innerHorizontal = 5
        model.settings.appearance.gaps.innerHorizontal = 6 // E.g. a slider is dragged
        model.settings.appearance.gaps.innerHorizontal = 7
        try await Task.sleep(for: .milliseconds(600))
        assertEquals(applied.map(\.appearance.gaps.innerHorizontal), [7])
    }

    /// A problem somewhere doesn't hold back the other edits (e.g. the gaps): they are saved and applied
    @Test func testSettingsWithProblemsAreAppliedWithoutTheInvalidParts() async throws {
        var applied: [Settings] = []
        let model = SettingsModel(settings: settings(), apply: { applied.append($0) })
        model.settings.modes[0].shortcuts[0].actions = [.custom("focus nowhere")]
        model.settings.appearance.gaps.innerHorizontal = 9
        assertEquals(model.problems.map(\.location), ["Shortcuts › main › alt-h"])
        assertEquals(model.problems(at: "Shortcuts").count, 1)
        try await Task.sleep(for: .milliseconds(600))
        assertEquals(applied.map(\.appearance.gaps.innerHorizontal), [9])
        assertEquals(applied.first.map { $0.compile().config.modes[mainModeId]?.bindings.count }, 0) // Left out

        model.settings.modes[0].shortcuts[0].actions = [.focus(.right)] // Fixed
        try await Task.sleep(for: .milliseconds(600))
        assertEquals(applied.count, 2)
        assertEquals(model.problems, [])
    }

    /// Opening the window again shows the settings on the disk without applying them again
    @Test func testReloadedSettingsAreShownNotApplied() async throws {
        var applied = 0
        let model = SettingsModel(settings: settings(), apply: { _ in applied += 1 })
        var other = settings()
        other.appearance.gaps.innerHorizontal = 3
        model.reload(other)
        assertEquals(model.settings, other)
        try await Task.sleep(for: .milliseconds(600))
        assertEquals(applied, 0)
    }

    /// An edit that waits to be applied is newer than the disk: it isn't replaced
    @Test func testReloadDoesNotDiscardAPendingEdit() async throws {
        var applied: [Settings] = []
        let model = SettingsModel(settings: settings(), apply: { applied.append($0) })
        model.settings.appearance.gaps.innerHorizontal = 7
        model.reload(settings())
        assertEquals(model.settings.appearance.gaps.innerHorizontal, 7)
        try await Task.sleep(for: .milliseconds(600))
        assertEquals(applied.map(\.appearance.gaps.innerHorizontal), [7])

        model.reload(settings()) // Applied meanwhile: the disk is the truth again
        assertEquals(model.settings, settings())
    }

    @Test func testUnchangedSettingsAreNotApplied() async throws {
        var applied = 0
        let model = SettingsModel(settings: settings(), apply: { _ in applied += 1 })
        model.settings = settings()
        try await Task.sleep(for: .milliseconds(600))
        assertEquals(applied, 0)
    }

    /// The config applied while a shortcut is recorded (an edit, a change of the keyboard layout, `reload-config`) keeps
    /// MarSpace's shortcuts paused: they would take the keys being recorded
    @Test func testShortcutsStayPausedWhenTheConfigIsAppliedMeanwhile() async {
        var settings = Settings()
        settings.workspaceShortcuts = .init(goTo: nil, moveWindowTo: nil)
        settings.modes = [Settings.BindingMode(name: mainModeId, shortcuts: [
            Settings.Shortcut(chord: KeyChord([.control, .option, .shift, .command], .f19), actions: [.focus(.left)]),
        ])]
        defer { resetHotKeys() }
        setHotkeysPaused(true)
        config = settings.compile().config
        await activateMode_nonCancellable(mainModeId)
        assertEquals(registeredHotkeys.count, 1)
        assertEquals(registeredHotkeys.filter(\.isEnabled).count, 0)

        setHotkeysPaused(false)
        assertEquals(registeredHotkeys.filter(\.isEnabled).count, 1)
    }

    /// A removal can be undone: from the banner, and with ⌘Z (and redone with ⇧⌘Z)
    @Test func testRemovalsCanBeUndone() {
        var two = settings()
        two.windowRules = [Settings.WindowRule(actions: [.closeWindow]), Settings.WindowRule(actions: [.balanceSizes])]
        let model = SettingsModel(settings: two, apply: { _ in })
        model.removing("Delete Rule", "Rule deleted") { model.settings.windowRules.remove(at: 0) }
        assertEquals(model.removal?.message, "Rule deleted")
        model.undoRemoval()
        assertEquals(model.settings, two)
        assertNil(model.removal)

        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        model.undoManager = undoManager
        undoManager.beginUndoGrouping()
        model.removing("Delete Rule", "Rule deleted") { model.settings.windowRules.remove(at: 1) }
        undoManager.endUndoGrouping()
        assertEquals(undoManager.undoActionName, "Delete Rule")
        undoManager.undo()
        assertEquals(model.settings, two)
        undoManager.redo()
        assertEquals(model.settings.windowRules.count, 1)

        model.removing("Delete Rule", "Rule deleted") {} // Nothing removed: nothing to undo
        assertNil(model.removal)
    }

    /// MarSpace's own shortcuts are paused while a shortcut is recorded
    @Test func testRecordingIsReported() {
        var reported: [Bool] = []
        let model = SettingsModel(settings: settings(), apply: { _ in }, onRecordingChange: { reported.append($0) })
        model.isRecordingShortcut = true
        model.isRecordingShortcut = true
        model.isRecordingShortcut = false
        assertEquals(reported, [true, false])
    }
}
