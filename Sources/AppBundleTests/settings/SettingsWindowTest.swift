import AppKit
@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct SettingsWindowTest {
    /// The settings window and its views exist only while it's open: nothing holds them after it's closed (they were
    /// most of the memory of MarSpace, which runs all day)
    @Test func testTheWindowAndItsViewsAreReleasedWhenItsClosed() async throws {
        _ = NSApplication.shared // The window tells the app that it has no Dock icon anymore
        let controller = SettingsWindowController()
        weak let window = controller.makeWindow()
        weak let model = controller.model
        weak let content = window?.contentViewController
        window?.layoutIfNeeded() // The views are built
        assertTrue(window != nil && model != nil && content != nil)

        window?.close()
        for _ in 0 ..< 100 where window != nil || model != nil || content != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        assertTrue(controller.window == nil)
        assertTrue(controller.model == nil)
        assertTrue(window == nil)
        assertTrue(model == nil)
        assertTrue(content == nil)

        // And it's built again when it's opened the next time
        weak let second = controller.makeWindow()
        assertTrue(second != nil && controller.model != nil)
        second?.close()
        for _ in 0 ..< 100 where second != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        assertTrue(second == nil)
    }
}
