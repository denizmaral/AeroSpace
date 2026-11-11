@testable import AppBundle
import Common
import Foundation
import Testing

@MainActor
@Suite(.serializedGlobally)
struct TerminationTest {
    private final class CountingHandler: TerminationHandler {
        @MainActor var count = 0
        @MainActor func beforeTermination() { count += 1 }
    }

    /// Quitting MarSpace in any way (not only with "Quit" in its menu: ⌘Q or the Dock while the settings window is open,
    /// logging out) puts the windows back on screen, once
    @Test func testEveryWayToQuitRunsTheTerminationHandlerOnce() {
        let handler = CountingHandler()
        let previous = terminationHandler
        unsafe _terminationHandler = handler
        didRunTerminationHandler = false
        defer {
            unsafe _terminationHandler = previous
            didRunTerminationHandler = false
        }

        MarSpaceAppDelegate().applicationWillTerminate(Notification(name: .init("test")))
        assertEquals(handler.count, 1)

        // "Quit" in the menu runs it, and then terminates the app
        runTerminationHandlerOnce()
        MarSpaceAppDelegate().applicationWillTerminate(Notification(name: .init("test")))
        assertEquals(handler.count, 1)
    }
}

struct TerminationFrameTest {
    private let main = MonitorRects(
        rect: Rect(topLeftX: 0, topLeftY: 0, width: 1800, height: 1169),
        visibleRect: Rect(topLeftX: 0, topLeftY: 39, width: 1800, height: 1130),
        isMain: true,
    )
    private let right = MonitorRects(
        rect: Rect(topLeftX: 1800, topLeftY: 0, width: 2560, height: 1440),
        visibleRect: Rect(topLeftX: 1800, topLeftY: 25, width: 2560, height: 1415),
        isMain: false,
    )

    /// A tiling window fills the part of its monitor that is free: below the menu bar, not behind it
    @Test func testTilingWindowFillsTheVisiblePartOfItsMonitor() throws {
        let window = Rect(topLeftX: 10, topLeftY: 50, width: 800, height: 1000)
        let frame = try #require(frameForTermination(window: window, floatingSize: nil, [main, right]))
        assertEquals(frame.topLeft, CGPoint(x: 0, y: 39))
        assertEquals(frame.size, CGSize(width: 1800, height: 1130))
    }

    /// The windows of the second monitor stay on it (they all went to the main monitor: the place was counted from its
    /// corner)
    @Test func testWindowStaysOnItsMonitor() throws {
        let window = Rect(topLeftX: 2000, topLeftY: 100, width: 800, height: 600)
        let frame = try #require(frameForTermination(window: window, floatingSize: CGSize(width: 1000, height: 700), [main, right]))
        assertEquals(frame.topLeft, CGPoint(x: 1800 + 780, y: 25 + 357.5))
        assertEquals(frame.size, CGSize(width: 1000, height: 700))
    }

    /// The window of a workspace that isn't shown is in the corner of its monitor, nearly all of it off screen
    @Test func testWindowInTheCornerGoesToTheNearestMonitor() throws {
        let hidden = Rect(topLeftX: 1800 + 2560 - 1, topLeftY: 1440 - 1, width: 900, height: 700)
        let frame = try #require(frameForTermination(window: hidden, floatingSize: nil, [main, right]))
        assertEquals(frame.topLeft, CGPoint(x: 1800, y: 25))
        assertEquals(frame.size, CGSize(width: 2560, height: 1415))
    }

    /// A floating window that is bigger than the monitor starts at its corner, not left of it
    @Test func testFloatingSizeBiggerThanTheMonitor() throws {
        let frame = try #require(frameForTermination(window: nil, floatingSize: CGSize(width: 3000, height: 500), [right, main]))
        assertEquals(frame.topLeft, CGPoint(x: 0, y: 39 + (1130 - 500) / 2))
    }

    @Test func testNoMonitor() {
        assertTrue(frameForTermination(window: nil, floatingSize: nil, []) == nil)
    }
}
