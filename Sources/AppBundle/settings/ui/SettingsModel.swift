import AppKit
import Common
import Observation

/// The state of the settings window: the settings themselves belong to ``SettingsStore`` (read and changed through it),
/// the window adds what only it knows (a shortcut being recorded, the keyboard layout of the key labels)
@MainActor
@Observable
final class SettingsModel {
    let store: SettingsStore

    /// A binding of the settings window writes through the store: a transaction, undoable
    var settings: Settings {
        get { store.settings }
        set { store.settings = newValue }
    }

    var removal: SettingsStore.Removal? { store.removal }

    /// Changes when the keyboard layout of macOS changes: the key labels of the shortcuts follow it
    var keyboardLayoutChanges = 0

    /// A key chord is being recorded: MarSpace's own shortcuts are paused meanwhile (they would take the keys)
    var isRecordingShortcut = false {
        didSet {
            guard isRecordingShortcut != oldValue else { return }
            onRecordingChange(isRecordingShortcut)
        }
    }

    private let onRecordingChange: @MainActor (Bool) -> Void

    init(store: SettingsStore, onRecordingChange: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.store = store
        self.onRecordingChange = onRecordingChange
    }

    func problems(at location: String) -> [SettingsProblem] { store.problems(at: location) }

    /// See ``SettingsStore/removing(_:_:_:)``
    func removing(_ actionName: String, _ message: String, _ change: (inout Settings) -> Void) {
        store.removing(actionName, message, change)
    }

    func undoRemoval() { store.undoRemoval() }
}
