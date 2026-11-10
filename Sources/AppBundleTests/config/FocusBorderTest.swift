@testable import AppBundle
import Common
import CoreGraphics
import Testing

@MainActor
@Suite(.serializedGlobally)
struct FocusBorderTest {
    init() { setUpWorkspacesForTests() }

    @Test func testDisabledByDefault() {
        let result = parseConfig("")
        assertEquals(result.errors, [])
        assertEquals(result.config.focusBorder, FocusBorder())
        assertEquals(result.config.focusBorder.enabled, false)
    }

    @Test func testParse() {
        let result = parseConfig(
            """
            [focus-border]
            enabled = true
            color = 'gradient(top_left=0xee33ccff,bottom_right=0xee00ff99)'
            width = 3
            radius = 16
            """,
        )
        assertEquals(result.errors, [])
        assertEquals(
            result.config.focusBorder,
            FocusBorder(enabled: true, color: .gradient(start: 0xEE33_CCFF, end: 0xEE00_FF99, fromTopLeft: true), width: 3, radius: 16),
        )
    }

    @Test func testParseErrors() {
        assertEquals(
            parseConfig("focus-border.color = 'red'").strErrors,
            ["[ERROR] focus-border.color: Can't parse color 'red'. Possible formats: 0xAARRGGBB, " +
                "gradient(top_left=0xAARRGGBB,bottom_right=0xAARRGGBB), gradient(top_right=0xAARRGGBB,bottom_left=0xAARRGGBB)"],
        )
        assertEquals(parseConfig("focus-border.width = 0").strErrors, ["[ERROR] focus-border.width: Must be in [1, 20] range"])
        assertEquals(parseConfig("focus-border.radius = 51").strErrors, ["[ERROR] focus-border.radius: Must be in [0, 50] range"])
        assertEquals(parseConfig("focus-border.foo = 1").strErrors.count, 1)
    }

    @Test func testParseColor() {
        assertEquals(parseFocusBorderColor("0xffe1e3e4"), .solid(0xFFE1_E3E4))
        assertEquals(parseFocusBorderColor("0xFFE1E3E4"), .solid(0xFFE1_E3E4))
        assertEquals(
            parseFocusBorderColor("gradient(top_right=0xee33ccff,bottom_left=0xee00ff99)"),
            .gradient(start: 0xEE33_CCFF, end: 0xEE00_FF99, fromTopLeft: false),
        )

        assertNil(parseFocusBorderColor("0xffe1e3"))
        assertNil(parseFocusBorderColor("0x+fe1e3e4"))
        assertNil(parseFocusBorderColor("ffe1e3e4ff"))
        assertNil(parseFocusBorderColor("gradient(top_left=0xee33ccff,bottom_left=0xee00ff99)"))
        assertNil(parseFocusBorderColor("gradient(top_left=0xee33ccff)"))
        assertNil(parseFocusBorderColor("gradient(top_left=0xee33ccff,bottom_right=0xee00ff99"))
    }

    @Test func testArgbCgColor() {
        let color = UInt32(0x80FF_0000).argbCgColor
        assertEquals(color.components?.map { ($0 * 255).rounded() }, [255, 0, 0, 128])
    }

    @Test func testPanelFrameSurroundsTheWindowInCocoaCoordinates() {
        // A window 100pt from the top of a 1169pt high main monitor
        let windowRect = Rect(topLeftX: 20, topLeftY: 100, width: 800, height: 600)
        assertEquals(
            focusBorderPanelFrame(windowRect: windowRect, borderWidth: 4, mainMonitorHeight: 1169),
            CGRect(x: 16, y: 465, width: 808, height: 608), // y = 1169 - 100 - 600 - 4
        )
    }

    @Test func testBorderSurroundsTheWindowInsideTheMonitor() {
        let monitor = Rect(topLeftX: 0, topLeftY: 0, width: 1800, height: 1169)
        let window = Rect(topLeftX: 10, topLeftY: 49, width: 960, height: 1110)
        assertEquals(focusBorderWindowRect(window, monitor: monitor, borderWidth: 4), window)
        // Touching the monitor edge is not beyond it
        let fullscreen = Rect(topLeftX: 0, topLeftY: 39, width: 1800, height: 1130)
        assertEquals(focusBorderWindowRect(fullscreen, monitor: monitor, borderWidth: 4), fullscreen)
        assertEquals(focusBorderWindowRect(window, monitor: nil, borderWidth: 4), window)
    }

    /// App Store (at least 1000 wide) placed at its 885 wide tile reaches 105 beyond the right edge of the monitor
    @Test func testBorderFollowsTheMonitorEdgeWhereTheWindowIsBeyondIt() {
        let monitor = Rect(topLeftX: 0, topLeftY: 0, width: 1800, height: 1169)
        assertEquals(
            focusBorderWindowRect(Rect(topLeftX: 905, topLeftY: 49, width: 1000, height: 1110), monitor: monitor, borderWidth: 4),
            Rect(topLeftX: 905, topLeftY: 49, width: 891, height: 1110), // The right edge at 1800 - 4
        )
        assertEquals(
            focusBorderWindowRect(Rect(topLeftX: -50, topLeftY: -20, width: 2000, height: 1300), monitor: monitor, borderWidth: 4),
            Rect(topLeftX: 4, topLeftY: 4, width: 1792, height: 1161),
        )
    }
}
