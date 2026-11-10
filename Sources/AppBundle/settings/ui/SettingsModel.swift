import AppKit
import Common
import Observation

/// The state of the settings window: the settings being edited and what's wrong with them. Every edit is compiled right
/// away (the problems are shown where they are) and saved and applied shortly after the last edit: nothing the user did is
/// lost, the invalid parts are left out until they are fixed
@MainActor
@Observable
final class SettingsModel {
    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            problems = settings.compile().problems
            if !isReloading { scheduleApply() }
        }
    }

    private(set) var problems: [SettingsProblem]

    /// Changes when the keyboard layout of macOS changes: the key labels of the shortcuts follow it
    var keyboardLayoutChanges = 0

    /// A key chord is being recorded: MarSpace's own shortcuts are paused meanwhile (they would take the keys)
    var isRecordingShortcut = false {
        didSet {
            guard isRecordingShortcut != oldValue else { return }
            onRecordingChange(isRecordingShortcut)
        }
    }

    private let apply: @MainActor (Settings) async -> Void
    private let onRecordingChange: @MainActor (Bool) -> Void
    @ObservationIgnored private var applyTask: Task<(), any Error>? = nil
    @ObservationIgnored private var applyGeneration = 0
    @ObservationIgnored private var isReloading = false

    init(
        settings: Settings,
        apply: @escaping @MainActor (Settings) async -> Void,
        onRecordingChange: @escaping @MainActor (Bool) -> Void = { _ in },
    ) {
        self.settings = settings
        self.problems = settings.compile().problems
        self.apply = apply
        self.onRecordingChange = onRecordingChange
    }

    func problems(at location: String) -> [SettingsProblem] {
        problems.filter { $0.location == location || $0.location.hasPrefix(location + " › ") }
    }

    /// The last removal (a rule, a shortcut, a workspace, …): the window offers to undo it for a while. ⌘Z undoes it too
    struct Removal: Equatable {
        /// For the Edit menu: "Undo Delete Rule"
        let actionName: String
        /// For the banner: "Rule deleted"
        let message: String
        let settingsBefore: Settings
        let id: Int
    }

    private(set) var removal: Removal? = nil
    @ObservationIgnored private var removalCount = 0
    /// The undo manager of the settings window: ⌘Z and Edit › Undo
    @ObservationIgnored weak var undoManager: UndoManager?

    /// Removes something: it can be undone (the banner, ⌘Z)
    /// - Parameters:
    ///   - actionName: for the Edit menu, e.g. "Delete Rule"
    ///   - message: for the banner, e.g. "Rule deleted"
    func removing(_ actionName: String, _ message: String, _ change: () -> Void) {
        let before = settings
        change()
        guard settings != before else { return }
        removalCount += 1
        let id = removalCount
        removal = Removal(actionName: actionName, message: message, settingsBefore: before, id: id)
        registerUndo(restoring: before, actionName)
        Task.startUnstructured { @MainActor in
            try await Task.sleep(for: .seconds(8))
            if self.removal?.id == id { self.removal = nil }
        }
    }

    /// Undoes the last removal (the button of the banner)
    func undoRemoval() {
        guard let removal else { return }
        if let undoManager, undoManager.canUndo, undoManager.undoActionName == removal.actionName {
            undoManager.undo() // Keeps ⌘⇧Z (redo) working
        } else {
            restore(removal.settingsBefore, removal.actionName)
        }
    }

    private func restore(_ value: Settings, _ description: String) {
        let current = settings
        settings = value
        removal = nil
        registerUndo(restoring: current, description) // Redo while undoing
    }

    private func registerUndo(restoring value: Settings, _ description: String) {
        undoManager?.registerUndo(withTarget: self) { model in model.restore(value, description) }
        undoManager?.setActionName(description)
    }

    /// The settings changed outside the window (e.g. restored from the backup): shown, not applied again. Not while an edit
    /// waits to be applied: the window is newer than the disk then
    func reload(_ settings: Settings) {
        guard applyTask == nil else { return }
        isReloading = true
        defer { isReloading = false }
        self.settings = settings
    }

    private func scheduleApply() {
        applyTask?.cancel()
        applyGeneration += 1
        let generation = applyGeneration
        let settings = settings
        applyTask = Task.startUnstructured { @MainActor in
            try await Task.sleep(for: .milliseconds(250)) // While the user drags a slider, apply its final value
            await self.apply(settings)
            if self.applyGeneration == generation { self.applyTask = nil }
        }
    }
}
