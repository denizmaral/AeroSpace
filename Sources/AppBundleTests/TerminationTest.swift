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
