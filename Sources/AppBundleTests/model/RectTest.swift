@testable import AppBundle
import Testing

@MainActor
@Suite
struct RectTest {
    @Test func testIntersection() {
        let monitor = Rect(topLeftX: 0, topLeftY: 0, width: 1800, height: 1169)
        // App Store placed at its tile reaches 105 beyond the monitor
        assertEquals(
            Rect(topLeftX: 905, topLeftY: 49, width: 1000, height: 1110).intersection(monitor),
            Rect(topLeftX: 905, topLeftY: 49, width: 895, height: 1110),
        )
        assertEquals(Rect(topLeftX: 10, topLeftY: 49, width: 960, height: 1110).intersection(monitor), Rect(topLeftX: 10, topLeftY: 49, width: 960, height: 1110))
        assertNil(Rect(topLeftX: 1800, topLeftY: 0, width: 100, height: 100).intersection(monitor)) // Only touching
    }
}
