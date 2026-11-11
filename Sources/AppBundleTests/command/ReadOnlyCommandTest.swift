@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct ReadOnlyCommandTest {
    init() { setUpWorkspacesForTests() }

    @Test func testQueriesAreReadOnly() {
        for command in [
            "list-windows --all", "list-workspaces --focused", "list-apps", "list-monitors", "list-modes",
            "list-exec-env-vars", "config --config-path", "echo -- hi", "test %{app-name} = foo", "true", "false",
        ] {
            #expect(parseCliArgs(command)?.isReadOnly == true, "\(command)")
        }
    }

    /// Read-only commands skip layout. A mutating command must never be read-only
    @Test func testMutatingCommandsAreNotReadOnly() {
        for command in [
            "focus left", "workspace 1", "move left", "layout floating", "pin", "close", "reload-config", "mode main",
            "move-node-to-workspace 2", "fullscreen", "balance-sizes", "enable toggle", "swap left", "tile-floating-windows",
        ] {
            #expect(parseCliArgs(command)?.isReadOnly == false, "\(command)")
        }
    }
}

/// Parses CLI args the same way the server does
@MainActor
private func parseCliArgs(_ command: String) -> (any Command)? {
    let parsed = parseCommand(command.split(separator: " ").map(String.init))
    if let error = parsed.errorOrNil { Issue.record("\(command): \(error)") }
    return parsed.cmdOrNil
}
