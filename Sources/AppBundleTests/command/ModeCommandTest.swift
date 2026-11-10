@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct ModeCommandTest {
    init() { setUpWorkspacesForTests() }

    @Test func testParse() {
        testParseSingleCommandSucc("mode main", ModeCmdArgs(rawArgs: []).with(\.targetMode, .initialized("main")))
        assertEquals(parseCommand("mode").errorOrNil, "ERROR: Argument '<binding-mode>' is mandatory")
    }

    @Test func testParseDoubleDash() {
        testParseSingleCommandSucc(
            "mode -- main",
            ModeCmdArgs(rawArgs: []).with(\.targetMode, .initialized("main")),
        )
        testParseSingleCommandSucc(
            "mode -- --foo",
            ModeCmdArgs(rawArgs: []).with(\.targetMode, .initialized("--foo")),
        )
        assertEquals(parseCommand("mode --").errorOrNil, "ERROR: Argument '<binding-mode>' is mandatory")
    }

    /// A mode that doesn't exist has no bindings: entering it would switch every shortcut off
    @Test func testUnknownModeFails() async {
        config.modes["service"] = Mode(bindings: [:])
        defer { activeMode = mainModeId }
        let result = await parseCommand("mode servce").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["The 'servce' mode doesn't exist. The modes: main, service"])
        assertEquals(activeMode, mainModeId)

        assertEquals(await parseCommand("mode service").cmdOrDie.run(.defaultEnv, .emptyStdin).exitCode.rawValue, 0)
        assertEquals(activeMode, "service")
    }
}
