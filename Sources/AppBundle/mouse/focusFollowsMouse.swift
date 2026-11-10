import AppKit
import Common

@MainActor private var focusFollowsMouseMonitor: Any? = nil
@MainActor private var focusFollowsTask: Task<(), any Error>? = nil
@MainActor private var mouseTracker = FocusFollowsMouseTracker()

@MainActor func syncFocusFollowsMouse(_ config: Config) {
    if config.focusFollowsMouse.enabled == (focusFollowsMouseMonitor != nil) {
        return
    }

    if !config.focusFollowsMouse.enabled {
        NSEvent.removeMonitor(focusFollowsMouseMonitor.orDie())
        focusFollowsMouseMonitor = nil
        focusFollowsTask?.cancel()
        focusFollowsTask = nil
        mouseTracker = FocusFollowsMouseTracker()
        return
    }

    // Interestingly, this callback seems to not fire when the mouse is down which is good,
    // because this is how I want it to work for windows/tabs/files dragging
    focusFollowsMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { @MainActor event in
        guard let token: RunSessionGuard = .isServerEnabled, !MissionControl.isActive else { return }
        let location = event.locationInWindow.withYAxisFlipped
        let window = location.monitorApproximation.visibleWorkspace.windowUnderMouse(location)
        let isRecheck: Bool
        switch mouseTracker.mouseMoved(over: window, focused: globalFocus.windowOrNil, now: .now) {
            case .stay: return
            case .leave:
                focusFollowsTask?.cancel()
                return
            case .enter:
                focusFollowsTask?.cancel()
                isRecheck = false
            case .recheck:
                // No check is running (the previous one scheduled this one). Its focus session may still be: not canceled
                isRecheck = true
        }
        focusFollowsTask = Task.startUnstructured { @MainActor in
            // Ignores macOS menubar dropdown, but, unfortunately, it doesn't ignore non-native menu-like fake windows.
            // todo: It would be cool to somehow reuse isWindowHeuristic logic here
            let real: Window? = switch await axWindowUnderMouse(location) {
                case .notAWindow: nil // E.g. a menu or a popover is over the window
                // Nothing if AeroSpace doesn't manage it
                case .window(let nativeWindowId, let pid): Window.get(byNativeId: nativeWindowId, pid: pid)
                case .unknown: window
            }
            try checkCancellation()
            guard let target = mouseTracker.checked(real: real, isRecheck: isRecheck, focused: globalFocus.windowOrNil, now: .now)
            else { return }
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
    mouseTracker = FocusFollowsMouseTracker(hitWindow: location.monitorApproximation.visibleWorkspace.windowUnderMouse(location))
}

/// Decides when focus-follows-mouse checks which window is really under the mouse, and which window it focuses.
///
/// The focus follows the mouse only when the mouse enters a different window (like Hyprland's `mouse_refocus = false`):
/// - mouseMoved events arrive at the display refresh rate. An in-memory hit test against the rects of the last layout
///   detects that the mouse entered another window: most events are handled without accessibility calls and without
///   refresh sessions. Only then the accessibility API tells which window is really on top under the mouse
/// - Small mouse moves don't steal the focus that was changed by other means (keyboard, Mission Control, cmd-tab)
///
/// The rects of the last layout are not what is on the screen everywhere: a window that refuses to shrink to its tile
/// (e.g. App Store is at least 1000 wide) covers a part of the next tile, a floating window can be behind a tiling one, a
/// menu or a popover can be over the window. Where the check finds another window than the hit test, the hit test can't
/// tell when the mouse crosses the real border. So the check runs again on mouse moves, at most once per
/// `recheckInterval`, until both agree or the mouse enters another window
@MainActor
struct FocusFollowsMouseTracker {
    static let recheckInterval: Duration = .milliseconds(100)

    enum MouseMove: Equatable {
        /// Over the same window. Nothing to do
        case stay
        /// Over another window that needs no check: none (e.g. a gap) or the focused window. A check of the previous one
        /// is obsolete
        case leave
        /// Over another window: check which window is really under the mouse. A check of the previous one is obsolete
        case enter
        /// Over the same window, where the previous check found another one on top: check again
        case recheck
    }

    /// The hit test result as of the previous mouseMoved event
    private weak var hitWindow: Window?
    /// The window that the last check found really under the mouse. nil: none that AeroSpace manages, or not checked
    private weak var realWindow: Window?
    /// The earliest next check while the hit test and the last check disagree. nil: they agree, or a check is running
    private var recheckAt: ContinuousClock.Instant? = nil

    init(hitWindow: Window? = nil) {
        self.hitWindow = hitWindow
    }

    mutating func mouseMoved(over window: Window?, focused: Window?, now: ContinuousClock.Instant) -> MouseMove {
        if window === hitWindow {
            guard let recheckAt, now >= recheckAt else { return .stay }
            self.recheckAt = nil
            return .recheck
        }
        hitWindow = window
        realWindow = nil
        recheckAt = nil
        guard let window, window != focused else { return .leave }
        return .enter
    }

    /// - Parameter real: the window really on top under the mouse. nil: not managed by AeroSpace, a menu or a popover
    /// - Returns: the window to focus
    mutating func checked(real: Window?, isRecheck: Bool, focused: Window?, now: ContinuousClock.Instant) -> Window? {
        let previous = realWindow
        realWindow = real
        recheckAt = real === hitWindow ? nil : now + Self.recheckInterval
        guard let real, real != focused else { return nil }
        // Moving inside the same window, the focus follows only into another window: the previous check found the window
        // that was focused by other means meanwhile, small mouse moves don't steal the focus from it
        return !isRecheck || real !== previous ? real : nil
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
