@testable import AppBundle
import Common
import Testing

/// The settings window applies valid settings shortly after the last edit, never invalid ones
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

    @Test func testInvalidSettingsAreNotApplied() async throws {
        var applied: [Settings] = []
        let model = SettingsModel(settings: settings(), apply: { applied.append($0) })
        model.settings.modes[0].shortcuts[0].actions = [.custom("focus nowhere")]
        assertEquals(model.problems.map(\.location), ["Shortcuts › main › alt-h"])
        assertEquals(model.problems(at: "Shortcuts").count, 1)
        try await Task.sleep(for: .milliseconds(600))
        assertEquals(applied.count, 0)

        model.settings.modes[0].shortcuts[0].actions = [.focus(.right)] // Fixed
        try await Task.sleep(for: .milliseconds(600))
        assertEquals(applied.count, 1)
        assertEquals(model.problems, [])
    }

    @Test func testUnchangedSettingsAreNotApplied() async throws {
        var applied = 0
        let model = SettingsModel(settings: settings(), apply: { _ in applied += 1 })
        model.settings = settings()
        try await Task.sleep(for: .milliseconds(600))
        assertEquals(applied, 0)
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
