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
        guard let token: RunSessionGuard = .isServerEnabled, !MissionControl.isActive else { return }
        let location = event.locationInWindow.withYAxisFlipped
        let window = location.monitorApproximation.visibleWorkspace.windowUnderMouse(location)
        if window === windowUnderMouse { return }
        windowUnderMouse = window
        focusFollowsTask?.cancel()
        guard let window, window != globalFocus.windowOrNil else { return }
        focusFollowsTask = Task.startUnstructured { @MainActor in
            // Ignores macOS menubar dropdown, but, unfortunately, it doesn't ignore non-native menu-like fake windows.
            // todo: It would be cool to somehow reuse isWindowHeuristic logic here
            let target: Window?
            switch await axWindowUnderMouse(location) {
                case .notAWindow:
                    // E.g. a menu or a popover is over the window. Retry a bit later, not on every mouse move: each check
                    // is an AX call. The task is canceled if the mouse enters another window meanwhile
                    try await Task.sleep(for: .milliseconds(150))
                    if windowUnderMouse === window { windowUnderMouse = nil }
                    return
                case .window(let nativeWindowId, let pid):
                    // The rects of the last layout don't know the z-order (e.g. a floating window behind a tiling one):
                    // the window that is really on top. Nothing if AeroSpace doesn't manage it
                    target = Window.get(byNativeId: nativeWindowId, pid: pid)
                case .unknown:
                    target = window
            }
            try checkCancellation()
            guard let target, target != globalFocus.windowOrNil else { return }
            try await runLightSession(.focusFollowsMouse, token) {
                _ = target.focusWindow()
                target.nativeFocus()
            }
        }
    }
}

/// E.g. after Mission Control, the mouse stopped over some window. It must not be focused until the mouse enters another
/// window
@MainActor func resetFocusFollowsMouse() {
    let location = NSEvent.mouseLocation.withYAxisFlipped
    windowUnderMouse = location.monitorApproximation.visibleWorkspace.windowUnderMouse(location)
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

private enum AxElementUnderMouse {
    /// The topmost window at the location
    case window(nativeWindowId: CGWindowID, pid: pid_t)
    /// E.g. a menu or a popover
    case notAWindow
    /// The accessibility API failed
    case unknown
}

@concurrent
private nonisolated func axWindowUnderMouse(_ location: CGPoint) async -> AxElementUnderMouse {
    let systemwide = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    guard unsafe AXUIElementCopyElementAtPosition(systemwide, Float(location.x), Float(location.y), &element) == .success,
          let element
    else { return topmostWindow(at: location).map { .window(nativeWindowId: $0.id, pid: $0.pid) } ?? .unknown }
    let window = element.get(Ax.roleAttr) == kAXWindowRole ? element : element.get(Ax.parentWindowRecursive)
    guard let window else {
        // The element has no window: a menu or a popover, or the content of System Settings (it's drawn by other
        // processes, its elements have no window attribute). The topmost window of the app at the location tells
        guard let pid = element.pid, let topmost = topmostWindow(at: location, of: pid) else { return .notAWindow }
        return topmost.layer == 0 ? .window(nativeWindowId: topmost.id, pid: pid) : .notAWindow
    }
    guard let nativeWindowId = window.containingNativeWindowId(), let pid = window.pid else {
        return topmostWindow(at: location).map { .window(nativeWindowId: $0.id, pid: $0.pid) } ?? .unknown
    }
    return .window(nativeWindowId: nativeWindowId, pid: pid)
}

/// The front most window at the location: of the app `pid` (any layer: its menus and popovers too), or of any other app
/// than AeroSpace (the focus border) in the normal layer. The window server knows the z-order, no accessibility calls
private nonisolated func topmostWindow(at location: CGPoint, of pid: pid_t? = nil) -> (id: CGWindowID, pid: pid_t, layer: Int)? {
    let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let ownPid = ProcessInfo.processInfo.processIdentifier
    for info in infos { // Front to back
        guard let owner = info[kCGWindowOwnerPID as String] as? Int32, owner != ownPid,
              let layer = info[kCGWindowLayer as String] as? Int,
              let id = info[kCGWindowNumber as String] as? Int,
              let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
              bounds.contains(location)
        else { continue }
        if let pid {
            if owner == pid { return (CGWindowID(id), owner, layer) }
        } else if layer == 0 {
            return (CGWindowID(id), owner, layer)
        }
    }
    return nil
}
