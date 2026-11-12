import Common
import Darwin

/// The focus after a window closed (see ``MacWindow/garbageCollect(skipClosedWindowsCache:)``).
///
/// A closed window moves the focus of macOS only if its app has the focus: macOS moves it within the app (to its next
/// window, maybe on another workspace, or nowhere: the app stays active without a window), or to another app if the app
/// quit with the window. Then the focus goes back to the workspace of the closed window, and macOS gets the focus of that
/// workspace (AeroSpace issue #65: an app left active without a window). The focus moved to another workspace at most a
/// second ago may have been moved by the close too (AeroSpace issue #1089).
///
/// Otherwise the focus stays where it is:
/// - another app is frontmost while the app of the closed window runs on: the user or an app activated it (cmd-tab, the
///   Dock, an app that closes its window and activates another app). A screen sharing app activated a browser and closed
///   its window: MarSpace went back to the previous workspace and activated Finder there, twice during a presentation
/// - an app that didn't have the focus quit: the focus stays with the app that has it. Another app quit in the background:
///   MarSpace activated Finder on the workspace of its window, during the same presentation
@MainActor
func moveFocusAfterClose(
    closedWindowParent parent: NonLeafTreeNodeObject,
    closedWindowPid: pid_t,
    isClosedWindowAppRunning: Bool,
    frontmost: FrontmostHistory,
) {
    guard let closedWindowWorkspace = parent.nodeWorkspace else { return }
    let focus = globalFocus
    // Its app quit with the window: the app that had the focus passed it on right now
    let mayHaveMovedTheFocus = frontmost.pid == closedWindowPid ||
        !isClosedWindowAppRunning && frontmost.passedTheFocusOn(closedWindowPid, within: .seconds(1))
    let isOnFocusedWorkspace = closedWindowWorkspace == focus.workspace
    let isOnWorkspaceJustLeft = closedWindowWorkspace == prevFocusedWorkspace && prevFocusedWorkspaceDate.distance(to: .now) < 1
    guard isOnFocusedWorkspace || isOnWorkspaceJustLeft && mayHaveMovedTheFocus else { return }
    switch parent.cases {
        case .tilingContainer, .floatingWindowsContainer, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer:
            let closedWindowFocus = closedWindowWorkspace.toLiveFocus()
            _ = setFocus(to: closedWindowFocus)
            // Guard against "Apple Reminders popup" bug: AeroSpace issue #201
            if mayHaveMovedTheFocus && focus.windowOrNil?.app.pid != closedWindowPid {
                closedWindowFocus.windowOrNil?.nativeFocus()
            }
        case .macosPopupWindowsContainer, // Don't switch back on popup destruction
             .workspace, // Workspace is invalid parent for windows
             .monitor, // Monitor is invalid parent for windows
             .workspacesContainer, // WorkspacesContainer is invalid parent for windows
             .macosMinimizedWindowsContainer: // Don't switch back on minimized windows destruction
            break
    }
}

/// The process exists. An app that just quit can still be running for `NSRunningApplication`: its termination and the
/// activation of the next app are separate notifications (see
/// ``moveFocusAfterClose(closedWindowParent:closedWindowPid:isClosedWindowAppRunning:frontmost:)``)
func isProcessAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}
