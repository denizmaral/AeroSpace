@testable import AppBundle
import Common
import CoreGraphics
import Testing

@MainActor
@Suite(.serializedGlobally)
struct FocusBorderTest {
    init() { setUpWorkspacesForTests() }

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
