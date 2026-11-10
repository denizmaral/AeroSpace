@testable import AppBundle
import Common
import Testing

struct ReloadConfigCommandTest {
    @Test func testWarningsGoToStderrAndDontFail() {
        let result = ReloadConfigResult(errors: [], warnings: ["The settings file was damaged"], warningsAsErrors: false)
        assertEquals(result.isOk, true)
        assertEquals(result.stdout, "")
        assertEquals(result.stderr, "The settings file was damaged")
    }

    @Test func testErrorsFail() {
        let result = ReloadConfigResult(errors: ["Shortcuts › main › alt-h: bad"], warnings: ["damaged"], warningsAsErrors: false)
        assertEquals(result.isOk, false)
        assertEquals(result.stdout, "Shortcuts › main › alt-h: bad")
        assertEquals(result.stderr, "damaged")
    }

    /// `reload-config --warnings-as-errors`: the flag was parsed and documented, and did nothing
    @Test func testWarningsAsErrors() {
        let result = ReloadConfigResult(errors: ["bad"], warnings: ["damaged"], warningsAsErrors: true)
        assertEquals(result.isOk, false)
        assertEquals(result.stdout, "damaged\n\nbad")
        assertEquals(result.stderr, "")
        assertEquals(ReloadConfigResult(errors: [], warnings: ["damaged"], warningsAsErrors: true).isOk, false)
        assertEquals(ReloadConfigResult(errors: [], warnings: [], warningsAsErrors: true).isOk, true)
        assertEquals(parseCommand("reload-config --warnings-as-errors").errorOrNil, nil)
    }
}
