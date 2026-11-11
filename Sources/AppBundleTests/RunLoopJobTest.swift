@testable import AppBundle
import Common
import Foundation
import Testing

@MainActor
@Suite(.serializedGlobally)
struct RunLoopJobTest {
    /// The job on the thread of an app knows the event of the refresh session that asked for it. The window detection
    /// relies on it: it waits while the mouse button is down, except in the startup session (the windows that are there
    /// when MarSpace starts aren't new)
    @Test func testJobKnowsTheEventOfItsRefreshSession() async throws {
        let thread = Thread {
            RunLoop.current.add(Port(), forMode: .default) // A run loop without a source returns right away
            CFRunLoopRun()
        }
        thread.start()
        defer { thread.runInLoopAsync(job: RunLoopJob(.nonCancellable)) { _ in CFRunLoopStop(CFRunLoopGetCurrent()) } }

        let duringStartup = try await $refreshSessionEvent.withValue(.startup) {
            try await thread.runInLoop(.cancellable) { _ in isStartup }
        }
        assertTrue(duringStartup)
        let later = try await $refreshSessionEvent.withValue(.globalObserverLeftMouseUp) {
            try await thread.runInLoop(.cancellable) { _ in isStartup }
        }
        assertFalse(later)
    }
}
