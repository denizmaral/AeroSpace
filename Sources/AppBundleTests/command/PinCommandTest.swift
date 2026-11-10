@testable import AppBundle
import Common
import Foundation
import Testing

/// A pinned floating window is on the workspace that its monitor shows (Hyprland's `pin`)
@MainActor
@Suite(.serializedGlobally)
struct PinCommandTest {
    init() { setUpWorkspacesForTests() }

    @Test func testParse() {
        testParseSingleCommandSucc("pin", PinCmdArgs(rawArgs: [], toggle: .toggle))
        testParseSingleCommandSucc("pin on", PinCmdArgs(rawArgs: [], toggle: .on))
        testParseSingleCommandSucc("pin off", PinCmdArgs(rawArgs: [], toggle: .off))
        assertEquals(parseCommand("pin up").errorOrNil, "ERROR: Can't parse 'up'. Possible values: on|off")
    }

    @Test func testOnlyAFloatingWindowIsPinned() async {
        let workspace = Workspace.get(byName: name)
        let tiling = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let floating = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)

        #expect(tiling.focusWindow())
        let result = await parseCommand("pin").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["Only a floating window can be pinned. 'layout floating' makes the window floating"])
        assertEquals(tiling.isPinned, false)
        assertEquals(await parseCommand("pin off").cmdOrDie.run(.defaultEnv, .emptyStdin).exitCode.rawValue, 0) // It isn't

        #expect(floating.focusWindow())
        await parseCommand("pin").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(floating.isPinned, true)
        await parseCommand("pin on").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(floating.isPinned, true)
        await parseCommand("pin").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(floating.isPinned, false)

        await parseCommand("pin on --window-id 2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(floating.isPinned, true)
        // Tiled again: the window has its place in the layout of one workspace
        await parseCommand("layout tiling").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(floating.isPinned, false)
    }

    @Test func testAPinnedWindowComesAlongToTheWorkspaceThatIsShown() async {
        let workspaceA = Workspace.get(byName: "a")
        let workspaceB = Workspace.get(byName: "b")
        let pinned = TestWindow.new(id: 1, parent: workspaceA.floatingWindowsContainer)
        let floating = TestWindow.new(id: 2, parent: workspaceA.floatingWindowsContainer)
        let tilingA = TestWindow.new(id: 3, parent: workspaceA.rootTilingContainer)
        let tilingB = TestWindow.new(id: 4, parent: workspaceB.rootTilingContainer)
        TestWindow.new(id: 5, parent: workspaceB.rootTilingContainer)
        #expect(tilingB.focusWindow()) // The most recent window of b
        #expect(tilingA.focusWindow())
        pinned.isPinned = true

        await refreshModel_nonCancellable()
        assertEquals(pinned.nodeWorkspace?.name, "a") // Its workspace is shown: nothing to do

        await parseCommand("workspace b").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await refreshModel_nonCancellable() // What a session does after the command, before the layout
        assertEquals(pinned.nodeWorkspace?.name, "b")
        assertEquals(pinned.isFloating, true)
        assertEquals(floating.nodeWorkspace?.name, "a")
        // It doesn't take the focus, now or the next time the workspace is shown
        assertEquals(globalFocus.windowOrNil?.windowId, 4)
        assertEquals(workspaceB.mostRecentWindowRecursive?.windowId, 4)

        await parseCommand("workspace a").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await refreshModel_nonCancellable()
        assertEquals(pinned.nodeWorkspace?.name, "a")
        assertEquals(globalFocus.windowOrNil?.windowId, 3)
    }

    @Test func testPinnedWindowsAreRemembered() throws {
        let placements = [
            WindowPlacement(nativeWindowId: 7, pid: 100, workspace: "1", isFloating: true, isPinned: true),
            WindowPlacement(nativeWindowId: 8, pid: 100, workspace: "1", isFloating: true),
            WindowPlacement(nativeWindowId: 9, pid: 100, workspace: "1", isFloating: false),
        ]
        let snapshot = try #require(WindowPlacementSnapshot(data: WindowPlacementSnapshot.encode(placements, bootSession: 1)))
        assertEquals(snapshot.all, placements)
        assertEquals(snapshot.all.map(\.isPinned), [true, false, false])
    }
}
