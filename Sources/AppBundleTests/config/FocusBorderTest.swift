@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct FocusBorderTest {
    init() { setUpWorkspacesForTests() }

    @Test func testAbsentSection() {
        let result = parseConfig("")
        assertEquals(result.errors, [])
        assertNil(result.config.focusBorder)
    }

    @Test func testParse() {
        let result = parseConfig(
            """
            [focus-border]
            enabled = true
            active-color = 'gradient(top_left=0xee33ccff,bottom_right=0xee00ff99)'
            inactive-color = '0xaa595959'
            width = 3
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(
            result.config.focusBorder,
            FocusBorder(enabled: true, activeColor: "gradient(top_left=0xee33ccff,bottom_right=0xee00ff99)", inactiveColor: "0xaa595959", width: 3),
        )
        assertEquals(
            result.config.focusBorder?.jankyBordersArgs,
            ["active_color=gradient(top_left=0xee33ccff,bottom_right=0xee00ff99)", "inactive_color=0xaa595959", "width=3.0", "hidpi=on"],
        )
    }

    @Test func testExplicitlyDisabled() {
        let result = parseConfig("focus-border.enabled = false")
        assertEquals(result.errors, [])
        assertEquals(result.config.focusBorder, FocusBorder(enabled: false))
    }

    @Test func testParseErrors() {
        assertEquals(
            parseConfig("focus-border.active-color = 'red'").strErrors,
            ["[ERROR] focus-border.active-color: Can't parse color 'red'. Possible formats: 0xAARRGGBB, glow(0xAARRGGBB), " +
                "gradient(top_left=0xAARRGGBB,bottom_right=0xAARRGGBB), gradient(top_right=0xAARRGGBB,bottom_left=0xAARRGGBB)"],
        )
        assertEquals(parseConfig("focus-border.width = 0").strErrors, ["[ERROR] focus-border.width: width must be in [1, 50] range"])
        assertEquals(parseConfig("focus-border.foo = 1").strErrors.count, 1)
    }

    @Test func testColorValidation() {
        #expect(isJankyBordersColor("0xffe1e3e4"))
        #expect(isJankyBordersColor("glow(0xffe1e3e4)"))
        #expect(isJankyBordersColor("gradient(top_left=0xee33ccff,bottom_right=0xee00ff99)"))
        #expect(isJankyBordersColor("gradient(top_right=0xee33ccff,bottom_left=0xee00ff99)"))

        #expect(!isJankyBordersColor("0xffe1e3"))
        #expect(!isJankyBordersColor("ffe1e3e4ff"))
        #expect(!isJankyBordersColor("glow(0xffe1e3e4"))
        #expect(!isJankyBordersColor("gradient(top_left=0xee33ccff,bottom_left=0xee00ff99)"))
        #expect(!isJankyBordersColor("gradient(top_left=0xee33ccff)"))
        #expect(!isJankyBordersColor("0xffe1e3e4; rm -rf ~"))
    }
}
