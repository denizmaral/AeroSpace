@testable import AppBundle
import Common
import CoreGraphics
import Testing

/// The external display is unplugged and the built-in one opened: the only screen is another one, at the same place.
/// The windows were laid out for the external display (and fought macOS, which kept them on the smaller screen)
@MainActor
@Suite(.serializedGlobally)
struct MonitorTest {
    init() { setUpWorkspacesForTests() }

    @Test func testMonitorFollowsTheScreenThatTookItsPlace() async throws {
        defer { gcMonitors() } // The monitor of the tests again
        let monitor = mainMonitorInfo.toMonitorOrRearrangeMonitors()
        let workspace = globalFocus.workspace
        let windows = [TestWindow.new(id: 1, parent: workspace.rootTilingContainer), TestWindow.new(id: 2, parent: workspace.rootTilingContainer)]

        let builtIn = ScreenForTest(name: "Built-in Retina Display", rect: Rect(topLeftX: 0, topLeftY: 0, width: 1800, height: 1169))
        gcMonitors([builtIn])
        #expect(mainMonitorInfo.toMonitorOrRearrangeMonitors() === monitor) // With its workspaces
        assertEquals(workspace.workspaceMonitorInfo.rect, builtIn.rect)

        try await workspace.layoutWorkspace()
        assertEquals(windows.map { $0.lastAppliedLayoutPhysicalRect?.width }, [900, 900])
        assertEquals(windows.map { $0.lastAppliedLayoutPhysicalRect?.minY }, [40, 40])
    }

    /// The Dock settles after the screen
    @Test func testMonitorFollowsTheDock() async throws {
        defer { gcMonitors() }
        let workspace = globalFocus.workspace
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 1800, height: 1169)
        gcMonitors([ScreenForTest(name: "Built-in Retina Display", rect: rect)])
        gcMonitors([ScreenForTest(name: "Built-in Retina Display", rect: rect, dockHeight: 90)])

        assertEquals(workspace.workspaceMonitorInfo.visibleRect.maxY, 1079)
        try await workspace.layoutWorkspace()
        #expect(try #require(window.lastAppliedLayoutPhysicalRect).maxY <= 1079) // Above the Dock
    }

    @Test func testNoScreenKeepsTheMonitors() {
        defer { gcMonitors() }
        let monitor = mainMonitorInfo.toMonitorOrRearrangeMonitors()
        let rect = monitor.info.rect
        gcMonitors([]) // Between two configurations of the displays
        #expect(mainMonitorInfo.toMonitorOrRearrangeMonitors() === monitor)
        assertEquals(monitor.info.rect, rect)
    }
}

private struct ScreenForTest: MonitorInfo {
    let monitorAppKitNsScreenScreensId = 1
    let name: String
    let rect: Rect
    var dockHeight: CGFloat = 0
    var visibleRect: Rect {
        Rect(topLeftX: rect.topLeftX, topLeftY: rect.topLeftY + 40, width: rect.width, height: rect.height - 40 - dockHeight)
    }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
    let isMain = true
}
