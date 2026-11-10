@testable import AppBundle
import Common
import Foundation
import Testing

/// The user's real settings (test-fixtures/user-settings.marspace) compile to exactly the recorded result
/// (test-fixtures/user-settings.compiled.txt): every phase of the settings architecture must keep it
/// (dev-docs/settings-architecture.md). Delete the recorded file to record it again, on purpose only
@MainActor
@Suite(.serializedGlobally)
struct SettingsCharacterizationTest {
    init() { setUpWorkspacesForTests() }

    @Test func testTheUserSettingsCompileToTheRecordedResult() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SettingsCharacterizationTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: projectRoot.appending(path: "test-fixtures/user-settings.marspace"),
            to: directory.appending(path: "Settings.marspace"),
        )
        guard case .loaded(let settings) = SettingsStore(directory: directory).load() else {
            Issue.record("The fixture can't be read")
            return
        }
        let snapshot = try Self.snapshot(of: settings)
        let recorded = projectRoot.appending(path: "test-fixtures/user-settings.compiled.txt")
        if let expected = try? String(contentsOf: recorded, encoding: .utf8) {
            assertEquals(snapshot, expected)
        } else {
            try snapshot.write(to: recorded, atomically: true, encoding: .utf8)
            Issue.record("Recorded \(recorded.path): check it and commit it")
        }
    }

    /// Everything the engine gets, in a stable order. The keys of the workspace shortcuts are those of a US keyboard
    static func snapshot(of settings: Settings) throws -> String {
        let (config, problems) = settings.compile(keyForCharacter: { getKeysPreset(.qwerty)[$0.lowercased()] })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var lines = ["problems: \(problems.map(\.description))"]
        for (mode, bindings) in config.modes.sorted(by: { $0.key < $1.key }) {
            for (key, binding) in bindings.bindings.sorted(by: { $0.key < $1.key }) {
                lines.append("binding \(mode) \(key): \(binding.commands.shellOfCommandsDescription)")
            }
        }
        for callback in config.onWindowDetected {
            let json = String(decoding: try encoder.encode(callback.debugJson), as: UTF8.self)
            lines.append("rule: \(json) check further: \(callback.checkFurtherCallbacks)")
        }
        lines += [
            "after startup: \(config.afterStartupCommand.shellOfCommandsDescription)",
            "focus changed: \(config.onFocusChanged.shellOfCommandsDescription)",
            "focused monitor changed: \(config.onFocusedMonitorChanged.shellOfCommandsDescription)",
            "mode changed: \(config.onModeChanged.shellOfCommandsDescription)",
            "gaps: \(config.gaps)",
            "focus border: \(config.focusBorder)",
            "persistent workspaces: \(Array(config.persistentWorkspaces))",
            "monitors: \(config.workspaceToMonitorForceAssignment.sorted(by: { $0.key < $1.key }))",
            "start at login: \(config.startAtLogin)",
            "focus follows mouse: \(config.focusFollowsMouse.enabled)",
            "new window placement: \(config.newWindowPlacement)",
            "root: \(config.defaultRootContainerLayout) \(config.defaultRootContainerOrientation)",
            "normalization: \(config.enableNormalizationFlattenContainers) \(config.enableNormalizationOppositeOrientationForNestedContainers)",
            "accordion padding: \(config.accordionPadding)",
            "unhide hidden apps: \(config.automaticallyUnhideMacosHiddenApps)",
            "keyboard: \(config.keyMapping.preset)",
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}
