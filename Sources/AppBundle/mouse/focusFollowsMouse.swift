import AppKit
import Common

@MainActor private var focusFollowsMouseMonitor: Any? = nil
@MainActor private var focusFollowsTask: Task<(), any Error>? = nil
/// The window under the mouse as of the previous mouseMoved event.
///
/// The focus follows the mouse only when the mouse enters a different window (like Hyprland's `mouse_refocus = false`):
/// - mouseMoved events arrive at the display refresh rate. Most of them don't cross window boundaries, and they are
///   handled without any accessibility calls and without refresh sessions
/// - Small mouse moves don't steal the focus that was changed by other means (keyboard, Mission Control, cmd-tab)
@MainActor private weak var windowUnderMouse: Window? = nil

@MainActor func syncFocusFollowsMouse(_ config: Config) {
    if config.focusFollowsMouse.enabled == (focusFollowsMouseMonitor != nil) {
        return
    }

    if !config.focusFollowsMouse.enabled {
        NSEvent.removeMonitor(focusFollowsMouseMonitor.orDie())
        focusFollowsMouseMonitor = nil
        focusFollowsTask?.cancel()
        focusFollowsTask = nil
        windowUnderMouse = nil
        return
    }

    // Interestingly, this callback seems to not fire when the mouse is down which is good,
    // because this is how I want it to work for windows/tabs/files dragging
    focusFollowsMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { @MainActor event in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        let location = event.locationInWindow.withYAxisFlipped
        let window = location.monitorApproximation.visibleWorkspace.windowUnderMouse(location)
        if window === windowUnderMouse { return }
        windowUnderMouse = window
        focusFollowsTask?.cancel()
        guard let window, window != globalFocus.windowOrNil else { return }
        focusFollowsTask = Task.startUnstructured { @MainActor in
            // Ignores macOS menubar dropdown, but, unfortunately, it doesn't ignore non-native menu-like fake windows.
            // todo: It would be cool to somehow reuse isWindowHeuristic logic here
            if await isAxWindowUnderMouse(location) == false { return }
            try checkCancellation()
            try await runLightSession(.focusFollowsMouse, token) {
                _ = window.focusWindow()
                window.nativeFocus()
            }
        }
    }
}

extension Workspace {
    /// In-memory hit testing against the rects of the last layout. No accessibility calls
    @MainActor
    fileprivate func windowUnderMouse(_ location: CGPoint) -> Window? {
        for child in floatingWindowsContainer._mruChildren { // Approximation of the z-order
            if let window = child as? Window, window.lastLayoutFloatingRect?.contains(location) == true {
                return window
            }
        }
        return location.findWindowRecursively(in: rootTilingContainer, virtual: false, fullscreenCoversAll: true)
    }
}

@concurrent
private nonisolated func isAxWindowUnderMouse(_ location: CGPoint) async -> Bool? {
    let systemwide = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    if unsafe AXUIElementCopyElementAtPosition(systemwide, Float(location.x), Float(location.y), &element) != .success {
        return nil
    }
    guard let element else { return nil }
    return element.get(Ax.parentWindowRecursive) != nil || element.get(Ax.roleAttr) == kAXWindowRole
}
