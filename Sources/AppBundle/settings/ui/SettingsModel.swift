import AppKit
import Common
import Observation

/// The state of the settings window: the settings being edited and what's wrong with them. Every edit is compiled right
/// away (the problems are shown where they are); a valid result is saved and applied shortly after the last edit, an
/// invalid one is neither saved nor applied
@MainActor
@Observable
final class SettingsModel {
    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            problems = settings.compile().problems
            scheduleApply()
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

    private func scheduleApply() {
        applyTask?.cancel()
        guard problems.isEmpty else { return }
        let settings = settings
        applyTask = Task.startUnstructured { @MainActor in
            try await Task.sleep(for: .milliseconds(250)) // While the user drags a slider, apply its final value
            await self.apply(settings)
        }
    }
}
