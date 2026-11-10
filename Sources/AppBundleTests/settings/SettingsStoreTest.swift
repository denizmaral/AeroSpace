@testable import AppBundle
import Common
import Foundation
import HotKey
import Testing

/// SettingsStore is the one owner of the settings: every change is a transaction (undo, save, apply), the disk is read
/// only by `load` (dev-docs/settings-architecture.md)
@MainActor
@Suite(.serializedGlobally)
struct SettingsStoreTest {
    init() { setUpWorkspacesForTests() }

    private func settings() -> Settings {
        var settings = Settings()
        settings.modes = [Settings.BindingMode(name: "main", shortcuts: [Settings.Shortcut(chord: KeyChord([.option], .h), actions: [.focus(.left)])])]
        return settings
    }

    private func repository() -> SettingsRepository {
        SettingsRepository(directory: FileManager.default.temporaryDirectory.appending(path: "SettingsStoreTest-\(UUID().uuidString)"))
    }

    @Test func testEditsAreAppliedOnceAfterTheLastEdit() async throws {
        var applied: [Settings] = []
        let store = SettingsStore(settings: settings(), repository: nil, applyToEngine: { applied.append($0) })
        store.update { $0.appearance.gaps.innerHorizontal = 5 }
        store.update { $0.appearance.gaps.innerHorizontal = 6 } // E.g. a slider is dragged
        store.settings.appearance.gaps.innerHorizontal = 7 // A binding of the settings window
        try await Task.sleep(for: .milliseconds(600))
        assertEquals(applied.map(\.appearance.gaps.innerHorizontal), [7])
    }

    /// A problem somewhere doesn't hold back the other edits (e.g. the gaps): they are saved and applied
    @Test func testSettingsWithProblemsAreAppliedWithoutTheInvalidParts() async throws {
        var applied: [Settings] = []
        let store = SettingsStore(settings: settings(), repository: nil, applyToEngine: { applied.append($0) })
        store.update {
            $0.modes[0].shortcuts[0].actions = [.custom("focus nowhere")]
            $0.appearance.gaps.innerHorizontal = 9
        }
        assertEquals(store.problems.map(\.location), ["Shortcuts › main › alt-h"])
        assertEquals(store.problems(at: "Shortcuts").count, 1)
        try await Task.sleep(for: .milliseconds(600))
        assertEquals(applied.map(\.appearance.gaps.innerHorizontal), [9])
        assertEquals(applied.first.map { $0.compile().config.modes[mainModeId]?.bindings.count }, 0) // Left out
    }

    @Test func testUnchangedSettingsAreNotApplied() async throws {
        var applied = 0
        let store = SettingsStore(settings: settings(), repository: nil, applyToEngine: { _ in applied += 1 })
        store.settings = settings()
        try await Task.sleep(for: .milliseconds(600))
        assertEquals(applied, 0)
    }

    /// The startup and `reload-config`: the settings on the disk replace the current ones and are applied right away
    @Test func testLoadReplacesTheSettingsAndAppliesThemNow() async throws {
        let repository = repository()
        var onDisk = settings()
        onDisk.appearance.gaps.innerHorizontal = 3
        try repository.save(onDisk)
        var applied: [Settings] = []
        let store = SettingsStore(settings: settings(), repository: repository, applyToEngine: { applied.append($0) })
        let undoManager = UndoManager()
        store.undoManager = undoManager
        undoManager.beginUndoGrouping()
        store.update("Delete Rule") { $0.windowRules = [] }
        undoManager.endUndoGrouping()

        _ = await store.load(dryRun: false)
        assertEquals(store.settings.appearance.gaps.innerHorizontal, 3)
        assertEquals(applied.last?.appearance.gaps.innerHorizontal, 3) // Without waiting
        #expect(!undoManager.canUndo) // The disk isn't undoable
    }

    /// A change that waits to be saved isn't lost by a load: it's saved first
    @Test func testLoadSavesAPendingEditFirst() async throws {
        let repository = repository()
        try repository.save(settings())
        let store = SettingsStore(settings: settings(), repository: repository, applyToEngine: { _ in })
        store.update { $0.appearance.gaps.innerHorizontal = 11 }
        _ = await store.load(dryRun: false)
        assertEquals(store.settings.appearance.gaps.innerHorizontal, 11)
    }

    @Test func testADryRunChangesNothing() async throws {
        let repository = repository()
        var onDisk = settings()
        onDisk.appearance.gaps.innerHorizontal = 3
        try repository.save(onDisk)
        var applied = 0
        let store = SettingsStore(settings: settings(), repository: repository, applyToEngine: { _ in applied += 1 })
        _ = await store.load(dryRun: true)
        assertEquals(store.settings, settings())
        assertEquals(applied, 0)
    }

    /// A removal can be undone: from the banner, and with ⌘Z (and redone with ⇧⌘Z)
    @Test func testRemovalsCanBeUndone() {
        var two = settings()
        two.windowRules = [Settings.WindowRule(actions: [.closeWindow]), Settings.WindowRule(actions: [.balanceSizes])]
        let store = SettingsStore(settings: two, repository: nil, applyToEngine: { _ in })
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        store.undoManager = undoManager

        undoManager.beginUndoGrouping()
        store.removing("Delete Rule", "Rule deleted") { $0.windowRules.remove(at: 1) }
        undoManager.endUndoGrouping()
        assertEquals(store.removal?.message, "Rule deleted")
        assertEquals(undoManager.undoActionName, "Delete Rule")
        store.undoRemoval()
        assertEquals(store.settings, two)
        assertNil(store.removal)
        undoManager.redo()
        assertEquals(store.settings.windowRules.count, 1)

        store.removing("Delete Rule", "Rule deleted") { _ in } // Nothing removed: nothing to undo
        assertNil(store.removal)
    }

    /// Typing or dragging a slider: the changes of a burst are one undo step
    @Test func testABurstOfEditsIsOneUndoStep() {
        let store = SettingsStore(settings: settings(), repository: nil, applyToEngine: { _ in })
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        undoManager.beginUndoGrouping()
        for gap in 1 ... 5 { store.update { $0.appearance.gaps.innerHorizontal = gap } }
        undoManager.endUndoGrouping()
        undoManager.undo()
        assertEquals(store.settings, settings())
        #expect(!undoManager.canUndo)
    }

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

    /// MarSpace's own shortcuts are paused while a shortcut is recorded
    @Test func testRecordingIsReported() {
        var reported: [Bool] = []
        let model = SettingsModel(store: SettingsStore(settings: settings(), repository: nil, applyToEngine: { _ in }), onRecordingChange: { reported.append($0) })
        model.isRecordingShortcut = true
        model.isRecordingShortcut = true
        model.isRecordingShortcut = false
        assertEquals(reported, [true, false])
    }
}
