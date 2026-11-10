@testable import AppBundle
import Common
import Foundation
import Testing

/// The settings of an older MarSpace lack the fields that came later: any field with a default value may be missing, at
/// every level (``DecodableWithDefaults()``). Only what identifies an item is required, and the values themselves (an
/// action, a color)
@MainActor
@Suite(.serializedGlobally)
struct SettingsDecodingTest {
    init() { setUpWorkspacesForTests() }

    @Test func testOnlyWhatIdentifiesAnItemIsRequired() throws {
        var settings = Settings.defaults
        settings.windowRules = [Settings.WindowRule(
            condition: .init(appBundleId: "com.apple.mail", appNamePattern: "Mail", windowTitlePattern: "Inbox", workspace: "M", duringStartup: true),
            actions: [.moveWindowToWorkspace("M")],
            checkFurtherRules: true,
        )]
        settings.workspaces.monitorAssignments = [Settings.MonitorAssignment(workspace: "1", monitors: [.main])]
        settings.automation.afterStartup = [.balanceSizes]
        settings.automation.onFocusChanged = [.moveMouse(.windowLazyCenter)]
        settings.automation.onModeChanged = [.reloadSettings]
        let saved = try unsafe PropertyListSerialization.propertyList(from: PropertyListEncoder().encode(settings), format: nil)

        var required: [String] = []
        for path in keyPaths(of: saved) {
            let data = try PropertyListSerialization.data(fromPropertyList: removing(path, from: saved), format: .binary, options: 0)
            if (try? PropertyListDecoder().decode(Settings.self, from: data)) == nil {
                required.append(path.map(\.description).joined(separator: "."))
            }
        }
        // Inside a value (an enum and its payload: a color, an action, a monitor), everything is the value
        let values = [
            "appearance.focusBorder.color.", "automation.afterStartup.0.", "automation.onFocusChanged.0.", "automation.onFocusedMonitorChanged.0.",
            "automation.onModeChanged.0.", "modes.0.shortcuts.0.actions.0.", "windowRules.0.actions.0.", "workspaces.monitorAssignments.0.monitors.0.",
        ]
        assertEquals(required.filter { path in !values.contains { path.hasPrefix($0) } }, [
            "modes.0.name", "modes.0.shortcuts.0.chord", "modes.0.shortcuts.0.chord.keyCode", "modes.0.shortcuts.0.chord.modifiers",
            "workspaces.monitorAssignments.0.workspace",
        ])
    }

    /// A field that is missing gets its default value: e.g. all of them
    @Test func testEmptySettingsAreTheDefaultsOfTheTypes() throws {
        let empty = try PropertyListEncoder().encode([String: Int]())
        assertEquals(try PropertyListDecoder().decode(Settings.self, from: empty), Settings())
    }
}

private enum PathComponent: CustomStringConvertible {
    case key(String)
    case index(Int)

    var description: String {
        switch self {
            case .key(let key): key
            case .index(let index): String(index)
        }
    }
}

/// Every key of every dictionary, through the first element of the arrays
private func keyPaths(of value: Any, _ prefix: [PathComponent] = []) -> [[PathComponent]] {
    switch value {
        case let dictionary as [String: Any]:
            dictionary.keys.sorted().flatMap { key in [prefix + [.key(key)]] + keyPaths(of: dictionary[key]!, prefix + [.key(key)]) }
        case let array as [Any]:
            array.first.map { keyPaths(of: $0, prefix + [.index(0)]) } ?? []
        default:
            []
    }
}

private func removing(_ path: [PathComponent], from value: Any) -> Any {
    guard let first = path.first else { return value }
    let rest = Array(path.dropFirst())
    switch (first, value) {
        case (.key(let key), var dictionary as [String: Any]):
            dictionary[key] = rest.isEmpty ? nil : removing(rest, from: dictionary[key]!)
            return dictionary
        case (.index(let index), var array as [Any]):
            array[index] = removing(rest, from: array[index])
            return array
        default:
            return value
    }
}
