@testable import AppBundle
import Testing

struct WindowExistenceTest {
    /// Every refresh session checks that the registered windows still exist. A window that its app lists does: only the
    /// others (on another macOS Space, a background tab, closed) are asked, with an accessibility call each
    @Test func testOnlyTheWindowsThatArentListedAreAsked() {
        let registered: [UInt32: String] = [1: "listed", 2: "on another Space", 3: "closed", 4: "listed too"]
        var asked: [String] = []
        let existing = registered.filterExisting(listed: [1, 4, 5]) { window in
            asked.append(window)
            return window != "closed"
        }
        assertEquals(existing, [1: "listed", 2: "on another Space", 4: "listed too"])
        assertEquals(asked.sorted(), ["closed", "on another Space"])
    }
}
