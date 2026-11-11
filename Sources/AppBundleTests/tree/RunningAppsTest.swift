import AppKit
@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct RunningAppsTest {
    /// The refresh sessions take the apps with a Dock icon from the observed instances, not from a new list of
    /// NSWorkspace (a round trip to Launch Services per app): both must tell the same
    @Test func testTheRegularAppsAreTheOnesOfNSWorkspace() {
        let expected = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != myPid }
            .map(\.processIdentifier)
        assertEquals(RunningApps.regular.map(\.pid).sorted(), expected.sorted())
        for pid in expected {
            assertTrue(RunningApps.isRunning(pid: pid))
        }
    }

    /// Every instance of an app (NSWorkspace gives a new one each time, and so do its notifications) leads to the one
    /// that is observed
    @Test func testEveryInstanceOfAnAppIsTheObservedOne() throws {
        guard let pid = RunningApps.regular.first?.pid else { return } // No app with a Dock icon, e.g. no login session
        let first = try #require(NSRunningApplication(processIdentifier: pid))
        let second = try #require(NSRunningApplication(processIdentifier: pid))
        assertTrue(first !== second)
        let observed = try #require(RunningApps.get(first))
        assertTrue(observed === RunningApps.get(second))
        assertEquals(observed.pid, pid)
        assertEquals(observed.bundleId, first.bundleIdentifier)
    }

    /// An app that quit is forgotten, and its instance with it. MarSpace crashed there (twice in ten minutes: whenever
    /// any app quit): the instance was released with its observations still on it
    @Test func testForgettingAnAppReleasesItsObservedInstance() throws {
        guard let pid = RunningApps.regular.first?.pid else { return } // No app with a Dock icon, e.g. no login session
        defer { RunningApps.sync() }
        RunningApps.sync(with: [])
        // Nothing else holds the instance, like the one of an app that quit: NSWorkspace doesn't list it anymore
        try autoreleasepool {
            let instance = try #require(NSRunningApplication(processIdentifier: pid))
            assertEquals(RunningApps.get(instance)?.pid, pid)
        }
        assertTrue(RunningApps.isRunning(pid: pid))
        RunningApps.sync(with: [])
        assertFalse(RunningApps.isRunning(pid: pid))
    }

    /// The frontmost app is observed, not asked for in every refresh session: it's the one of NSWorkspace
    @Test func testFrontmostIsTheOneOfNSWorkspace() {
        let expected = NSWorkspace.shared.frontmostApplication.map(\.processIdentifier).flatMap { $0 == myPid ? nil : $0 }
        assertEquals(RunningApps.frontmost?.pid, expected)
        assertEquals(RunningApps.frontmost?.pid, expected) // From the observation
    }

    /// Accessibility requests crash if you send them to yourself
    @Test func testMarSpaceItselfIsNotAnApp() {
        assertNil(RunningApps.get(.current))
        assertFalse(RunningApps.isRunning(pid: myPid))
    }

    @Test func testUnknownPidIsNotRunning() {
        assertFalse(RunningApps.isRunning(pid: -1))
    }
}
