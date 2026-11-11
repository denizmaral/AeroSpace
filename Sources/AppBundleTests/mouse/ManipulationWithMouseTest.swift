@testable import AppBundle
import Common
import CoreGraphics
import Testing

/// A window that is moved or resized with the mouse is left alone by the layout, and the tiling trees aren't persisted
/// while it's dragged. The drag is over when the button is up, also if the mouse up wasn't seen (the global monitor
/// doesn't see it in MarSpace's own windows, the last session of the drag marked the window again after it): layout
/// changes made with the keyboard afterwards were lost when MarSpace restarted (`layout accordion`, `layout tiles`)
@MainActor
@Suite(.serializedGlobally)
struct ManipulationWithMouseTest {
    init() { setUpWorkspacesForTests() }

    @Test func testDragIsOverWhenTheButtonIsUp() async throws {
        let workspace = Workspace.get(byName: name)
        let dragged = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        #expect(dragged.focusWindow())
        try await workspace.layoutWorkspace()
        currentlyManipulatedWithMouseWindowId = dragged.windowId // The mouse up was missed. The button is up in tests

        _ = await parseCommand("layout v_tiles").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await refreshModel_nonCancellable() // What a session does after the command, before the layout and the persistence
        assertEquals(currentlyManipulatedWithMouseWindowId, nil)
        try await workspace.layoutWorkspace()
        assertEquals(dragged.sentFrames.last?.size, CGSize(width: 1920, height: 539.5))
    }

    @Test func testMouseUpWithoutDragAsksForNoSession() async throws {
        let asked = { completeRefreshSessionsAskedForInTests.count { if case .resetManipulatedWithMouse = $0 { true } else { false } } }
        try await resetManipulatedWithMouseIfPossible()
        assertEquals(asked(), 0)

        currentlyManipulatedWithMouseWindowId = 1
        try await resetManipulatedWithMouseIfPossible()
        assertEquals(currentlyManipulatedWithMouseWindowId, nil)
        assertEquals(asked(), 1)
    }
}
