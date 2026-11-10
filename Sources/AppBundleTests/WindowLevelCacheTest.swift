@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct WindowLevelCacheTest {
    /// The second request arrives while the first one is still asking the window server: it waits for the same answer.
    /// It must be woken up when the answer is there (it wasn't: the command or the refresh session behind it hung)
    @Test func testConcurrentRequestsBothReturn() async throws {
        let unknownWindowId: UInt32 = 0xFFFF_FFF0 // A miss: the window server is asked
        let first = Task.startUnstructured { @MainActor in _ = try await getWindowLevel(forNativeId: unknownWindowId, .cancellable) }
        let second = Task.startUnstructured { @MainActor in _ = try await getWindowLevel(forNativeId: unknownWindowId, .cancellable) }
        let timeout = Task.startUnstructured { @MainActor in
            try await Task.sleep(for: .seconds(10))
            first.cancel()
            second.cancel()
        }
        defer { timeout.cancel() }
        try await first.value
        try await second.value
    }
}
