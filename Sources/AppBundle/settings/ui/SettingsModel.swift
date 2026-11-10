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
