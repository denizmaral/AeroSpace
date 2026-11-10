import AppKit
import Common
import Observation

/// The one owner of the settings (dev-docs/settings-architecture.md). Nothing else holds or writes them: the settings
/// window, `reload-config`, the startup and a change of the keyboard layout all go through it.
///
/// A change is a transaction (``update(_:_:)``): it registers its undo, the problems are known right away, and the result
/// is saved and applied to the engine shortly after the last change (a slider that is dragged applies its final value).
/// Invalid parts are left out until they are fixed: nothing the user did is lost
@MainActor
@Observable
final class SettingsStore {
    /// Tests never touch the settings of the user, nor the engine through it
    static let shared = SettingsStore(
        repository: isUnitTest ? nil : .applicationSupport,
        applyToEngine: { if !isUnitTest { await applySettingsToEngine($0) } },
    )

    /// Writing goes through ``update(_:_:)``: a change made through a binding of the settings window is a transaction too
    var settings: Settings {
        get { current }
        set { update { $0 = newValue } }
    }

    private(set) var problems: [SettingsProblem]

    /// The last removal (a rule, a shortcut, a workspace, …): the settings window offers to undo it for a while
    private(set) var removal: Removal? = nil

    struct Removal: Equatable {
        /// For the Edit menu: "Undo Delete Rule"
        let actionName: String
        /// For the banner: "Rule deleted"
        let message: String
        let id: Int
    }

    /// The undo manager of the settings window: ⌘Z, ⇧⌘Z and the Edit menu
    @ObservationIgnored weak var undoManager: UndoManager?

    private var current: Settings
    private let repository: SettingsRepository?
    private let applyToEngine: @MainActor (Settings) async -> Void
    @ObservationIgnored private var commitTask: Task<(), any Error>? = nil
    @ObservationIgnored private var editBurst: Task<(), any Error>? = nil
    @ObservationIgnored private var removalCount = 0

    /// - Parameter repository: where the settings are saved. nil: not saved (tests)
    init(
        settings: Settings = Settings(),
        repository: SettingsRepository?,
        applyToEngine: @escaping @MainActor (Settings) async -> Void,
    ) {
        current = settings
        problems = settings.compile().problems
        self.repository = repository
        self.applyToEngine = applyToEngine
    }

    func problems(at location: String) -> [SettingsProblem] {
        problems.filter { $0.location == location || $0.location.hasPrefix(location + " › ") }
    }

    // MARK: Changes

    /// The only way to change the settings.
    /// - Parameter actionName: for the Edit menu ("Undo Delete Rule"). nil: the changes of a burst (typing, dragging a
    ///   slider) are one undo step
    func update(_ actionName: String? = nil, _ change: (inout Settings) -> Void) {
        var value = current
        change(&value)
        guard value != current else { return }
        let before = current
        set(value)
        if let actionName {
            registerUndo(restoring: before, actionName)
        } else {
            if editBurst == nil { registerUndo(restoring: before, "Change") }
            editBurst?.cancel()
            editBurst = Task.startUnstructured { @MainActor in
                try await Task.sleep(for: .seconds(1))
                self.editBurst = nil
            }
        }
    }

    /// Removes something. The settings window offers to undo it (and ⌘Z does)
    /// - Parameters:
    ///   - actionName: for the Edit menu, e.g. "Delete Rule"
    ///   - message: for the banner, e.g. "Rule deleted"
    func removing(_ actionName: String, _ message: String, _ change: (inout Settings) -> Void) {
        let before = current
        update(actionName, change)
        guard current != before else { return }
        removalCount += 1
        let id = removalCount
        removal = Removal(actionName: actionName, message: message, id: id)
        Task.startUnstructured { @MainActor in
            try await Task.sleep(for: .seconds(8))
            if self.removal?.id == id { self.removal = nil }
        }
    }

    /// The Undo button of the banner
    func undoRemoval() {
        guard let removal, let undoManager, undoManager.canUndo, undoManager.undoActionName == removal.actionName else { return }
        undoManager.undo()
    }

    private func set(_ value: Settings) {
        current = value
        problems = value.compile().problems
        scheduleCommit()
    }

    private func restore(_ value: Settings, _ actionName: String) {
        let undone = current
        set(value)
        removal = nil
        registerUndo(restoring: undone, actionName) // The redo, while undoing
    }

    private func registerUndo(restoring value: Settings, _ actionName: String) {
        undoManager?.registerUndo(withTarget: self) { store in store.restore(value, actionName) }
        undoManager?.setActionName(actionName)
    }

    /// The user moved a window of the app to a workspace with a shortcut: see ``Settings/assign(_:toWorkspace:)``. Not an
    /// edit of the settings window: not undoable there
    func assign(_ bundleId: String, toWorkspace workspace: String) {
        var value = current
        value.assign(bundleId, toWorkspace: workspace)
        if value != current { set(value) }
    }

    // MARK: Saving and applying

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task.startUnstructured { @MainActor in
            try await Task.sleep(for: .milliseconds(250))
            self.commitTask = nil
            await self.commit()
        }
    }

    /// Saves and applies the current settings. A change that waits is committed first
    private func commit() async {
        do {
            try repository?.save(current)
        } catch {
            MessageModel.shared.message = Message(
                description: "\(aeroSpaceAppName) Settings",
                body: "The settings can't be saved: \(error.localizedDescription)",
            )
            return
        }
        await applyToEngine(current)
    }

    /// Loads the settings from the disk and applies them right away: the startup, `reload-config`. A change that waits is
    /// saved first. Not undoable: the undo of the settings window is cleared. A dry run only reads them
    func load(dryRun: Bool) async -> (problems: [SettingsProblem], notices: [String]) {
        if !dryRun, commitTask != nil {
            commitTask?.cancel()
            commitTask = nil
            try? repository?.save(current)
        }
        let loaded = loadSettings(store: repository ?? .applicationSupport, dryRun: dryRun)
        let loadedProblems = loaded.settings.compile().problems
        if dryRun { return (loadedProblems, loaded.notices) }
        current = loaded.settings
        problems = loadedProblems
        removal = nil
        undoManager?.removeAllActions() // Nothing of the window is meaningful for the settings of the disk
        await applyToEngine(current)
        return (loadedProblems, loaded.notices)
    }

    /// The same settings compile to other keys: the keyboard layout of macOS changed
    func reapply() async {
        problems = current.compile().problems
        await applyToEngine(current)
    }
}

/// The compiled settings become the configuration of the engine. The next refresh session lays the windows out
@MainActor
func applySettingsToEngine(_ settings: Settings) async {
    let (config, problems) = settings.compile()
    TrayMenuModel.shared.settingsHaveProblems = !problems.isEmpty
    await applyConfig_nonCancellable(config)
    scheduleCancellableCompleteRefreshSession(.settingsChanged) // Gaps, border, layout
}
