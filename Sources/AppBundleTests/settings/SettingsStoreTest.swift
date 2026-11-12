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

    /// The editor of a rule closes right after the rule was changed: the engine gets the rule as it is before it runs
    @Test func testAnEditedRuleRunsAfterItIsApplied() async throws {
        var events: [String] = []
        let store = SettingsStore(
            settings: settings(), repository: nil,
            applyToEngine: { events.append("apply \($0.windowRules.count) rule") },
            runWindowRule: { _ in events.append("run") },
        )
        store.update("Add Rule") { $0.windowRules.append(Settings.WindowRule(actions: [.layout([.floating])])) }
        let id = try #require(store.settings.windowRules.lastId)
        await store.finishedEditing(windowRule: id)
        assertEquals(events, ["apply 1 rule", "run"])

        try await Task.sleep(for: .milliseconds(600))
        assertEquals(events, ["apply 1 rule", "run"]) // Applied once
        await store.finishedEditing(windowRule: id) // Nothing waits
        assertEquals(events, ["apply 1 rule", "run", "run"])
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

    /// Applying settings changes only what changed: a hotkey whose keys are still bound stays registered (its commands are
    /// looked up when it fires), keys that aren't bound anymore are unregistered, new ones registered
    @Test func testHotkeysAreAppliedByWhatChanged() async {
        func compiled(_ shortcuts: [(Key, Action)]) -> Config {
            var settings = Settings()
            settings.workspaceShortcuts = .init(goTo: nil, moveWindowTo: nil)
            settings.modes = [Settings.BindingMode(name: mainModeId, shortcuts: IdentifiedList(shortcuts.map {
                Settings.Shortcut(chord: KeyChord([.control, .option, .shift, .command], $0.0), actions: [$0.1])
            }))]
            return settings.compile().config
        }
        defer { resetHotKeys() }
        await applyConfig_nonCancellable(compiled([(.f17, .focus(.left)), (.f18, .focus(.right))]))
        let before = registeredHotkeys // Kept alive: a freed hotkey's memory (and identifier) could be reused
        assertEquals(before.count, 2)

        await applyConfig_nonCancellable(compiled([(.f17, .focus(.up)), (.f19, .focus(.down))])) // F17 changed, F18 gone, F19 new
        let after = registeredHotkeys
        assertEquals(after.count, 2)
        assertEquals(after.count(where: { new in before.contains { $0 === new } }), 1) // F17: the same hotkey
        assertEquals(config.modes[mainModeId]?.bindings.values.map(\.commands.shellOfCommandsDescription).sorted(), ["focus down", "focus up"])
    }

    /// MarSpace's own shortcuts are paused while a shortcut is recorded
    @Test func testRecordingIsReported() {
        var reported: [Bool] = []
        let model = SettingsModel(store: SettingsStore(settings: settings(), repository: nil, applyToEngine: { _ in }), onRecordingChange: { reported.append($0) })
        model.isRecordingShortcut = true
        model.isRecordingShortcut = true
        model.isRecordingShortcut = false
        assertEquals(reported, [true, false])
    }

    /// The mode that the user is in is removed in the settings window: its shortcuts are gone, the one that leaves it too
    @Test func testARemovedActiveModeFallsBackToMain() async {
        func compiled(modes: [String]) -> Config {
            var settings = Settings()
            settings.workspaceShortcuts = .init(goTo: nil, moveWindowTo: nil)
            settings.modes = modes.map { Settings.BindingMode(name: $0, shortcuts: []) }
            return settings.compile().config
        }
        defer { resetHotKeys() }
        await applyConfig_nonCancellable(compiled(modes: [mainModeId, "service"]))
        await activateMode_nonCancellable("service")
        await applyConfig_nonCancellable(compiled(modes: [mainModeId, "service"]))
        assertEquals(activeMode, "service")

        await applyConfig_nonCancellable(compiled(modes: [mainModeId]))
        assertEquals(activeMode, mainModeId)
    }
}
