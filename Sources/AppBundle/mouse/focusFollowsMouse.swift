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
        let windows = location.monitorApproximation.visibleWorkspace.windowsUnderMouse(location)
        switch mouseTracker.mouseMoved(over: windows, focused: globalFocus.windowOrNil, focusChanges: focusChangesByOtherMeans, now: .now) {
            case .stay: return
            case .leave:
                focusFollowsTask?.cancel()
                return
            case .enter: focusFollowsTask?.cancel()
            case .recheck: break // No check is running (one at a time)
        }
        focusFollowsTask = Task.startUnstructured { @MainActor in
            // Ignores macOS menubar dropdown, but, unfortunately, it doesn't ignore non-native menu-like fake windows.
            // todo: It would be cool to somehow reuse isWindowHeuristic logic here
            let real: Window? = switch await axWindowUnderMouse(location) {
                case .notAWindow: nil // E.g. a menu or a popover is over the window
                // Nothing if AeroSpace doesn't manage it
                case .window(let nativeWindowId, let pid): Window.get(byNativeId: nativeWindowId, pid: pid)
                case .unknown: windows.count == 1 ? windows.first : nil
            }
            try checkCancellation()
            guard let target = mouseTracker.checked(
                real: real, focused: globalFocus.windowOrNil, focusChanges: focusChangesByOtherMeans, now: .now,
            ) else { return }
            // Not canceled by later mouse moves: the tracker took the window as the one under the mouse, it wouldn't try again
            Task.startUnstructured { @MainActor in
                try await runLightSession(.focusFollowsMouse, token) {
                    _ = target.focusWindow()
                    target.nativeFocus()
                }
            }
        }
    }
}

/// E.g. after Mission Control, the mouse stopped over some window. It must not be focused until the mouse enters another
/// window
@MainActor func resetFocusFollowsMouse() {
    focusFollowsTask?.cancel()
    let location = NSEvent.mouseLocation.withYAxisFlipped
    let windows = location.monitorApproximation.visibleWorkspace.windowsUnderMouse(location)
    mouseTracker = FocusFollowsMouseTracker(windowsUnderMouse: windows, focused: globalFocus.windowOrNil)
}

/// Decides when focus-follows-mouse checks which window is really under the mouse, and which window it focuses.
///
/// The focus follows the mouse when the window really under the mouse changes (like Hyprland's `mouse_refocus = false`):
/// - mouseMoved events arrive at the display refresh rate. An in-memory hit test against the observed frames of the
///   windows (``Window/observedFrame``: what the user sees, a window can be bigger than its tile) tells which windows are
///   under the mouse. Nothing happens while they stay the same: no accessibility calls and no refresh sessions
/// - When they change, the window on top is known without accessibility calls if it's the focused one (it's in front of
///   the others) or the only one. Otherwise, and before focusing another window, the accessibility API tells which window
///   is really on top: the windows overlap, a floating window can be behind a tiling one, a menu, a popover or a window
///   that AeroSpace doesn't manage can be over them
/// - It's focused only if it's another window than the one that was really under the mouse before. Moving the mouse
///   doesn't steal the focus that was changed by other means (keyboard, Mission Control, cmd-tab) while the mouse stays
///   over the same window, also where it passes over the border of a window behind it
/// - A check that started before the focus was changed by other means doesn't focus anything: the later action wins (the
///   first accessibility call to an app can take a while)
@MainActor
struct FocusFollowsMouseTracker {
    static let recheckInterval: Duration = .milliseconds(100)

    enum MouseMove: Equatable {
        /// Over the same windows. Nothing to do
        case stay
        /// Over other windows, the window on top is known (none, the focused one, or the same as before): nothing to focus.
        /// A check under way is obsolete
        case leave
        /// Over other windows: check which window is really on top. A check under way is obsolete
        case enter
        /// Over the same windows, where the previous check found no window that AeroSpace manages on top (e.g. a menu):
        /// check again
        case recheck
    }

    /// The windows under the mouse as of the previous mouseMoved event
    private var windowIds: Set<OpaqueWindowId>
    /// The window really on top under the mouse. nil: none that AeroSpace manages
    private weak var realWindow: Window?
    /// false: which window is on top under the mouse is not known (overlapping windows, not checked yet)
    private var isRealWindowKnown: Bool
    /// The earliest next check while no window that AeroSpace manages is found on top. nil: no check is needed, or one is
    /// running
    private var recheckAt: ContinuousClock.Instant? = nil
    /// ``focusChangesByOtherMeans`` when the running check started
    private var focusChangesAtCheckStart: UInt = 0

    /// - Parameter windows: the windows under the mouse right now. The one on top is not focused until the mouse enters
    ///   another window
    init(windowsUnderMouse windows: [Window] = [], focused: Window? = nil) {
        windowIds = Set(windows.map(\.windowId))
        let top = Self.knownTop(windows, focused: focused)
        realWindow = top
        isRealWindowKnown = top != nil || windows.isEmpty
    }

    /// - Parameter windows: the windows whose observed frames contain the mouse location
    /// - Parameter focusChanges: ``focusChangesByOtherMeans``
    mutating func mouseMoved(over windows: [Window], focused: Window?, focusChanges: UInt, now: ContinuousClock.Instant) -> MouseMove {
        if windows.count == windowIds.count, windows.allSatisfy({ windowIds.contains($0.windowId) }) {
            guard let recheckAt, now >= recheckAt else { return .stay }
            self.recheckAt = nil
            focusChangesAtCheckStart = focusChanges
            return .recheck
        }
        windowIds = Set(windows.map(\.windowId))
        recheckAt = nil
        if windows.isEmpty {
            realWindow = nil
            isRealWindowKnown = true
            return .leave
        }
        if let top = Self.knownTop(windows, focused: focused), top == focused || isRealWindowKnown && top === realWindow {
            realWindow = top
            isRealWindowKnown = true
            return .leave
        }
        focusChangesAtCheckStart = focusChanges
        return .enter
    }

    /// - Parameter real: the window really on top under the mouse. nil: not managed by AeroSpace, a menu or a popover
    /// - Returns: the window to focus
    /// - Parameter focusChanges: ``focusChangesByOtherMeans``
    mutating func checked(real: Window?, focused: Window?, focusChanges: UInt, now: ContinuousClock.Instant) -> Window? {
        let previous: Window?? = isRealWindowKnown ? .some(realWindow) : .none
        realWindow = real
        isRealWindowKnown = true
        // E.g. a menu over the window: the window is focused when the menu is closed and the mouse moves
        recheckAt = real == nil ? now + Self.recheckInterval : nil
        guard let real, real != focused, previous.map({ real !== $0 }) ?? true, focusChanges == focusChangesAtCheckStart else { return nil }
        return real
    }

    /// The window on top without accessibility calls: the only one, or the focused one (it's in front of the others). Not
    /// if another floating window is there: a window can float above the focused one without being focused (always on
    /// top, a panel)
    private static func knownTop(_ windows: [Window], focused: Window?) -> Window? {
        if windows.count == 1 { return windows.first }
        guard let focused, windows.contains(focused), !windows.contains(where: { $0 != focused && $0.isFloating }) else { return nil }
        return focused
    }
}

extension Workspace {
    /// In-memory hit testing against the observed frames. No accessibility calls
    @MainActor
    func windowsUnderMouse(_ location: CGPoint) -> [Window] {
        var result: [Window] = []
        floatingWindowsContainer.appendWindows(at: location, to: &result)
        rootTilingContainer.appendWindows(at: location, to: &result)
        return result
    }
}

extension TreeNode {
    @MainActor
    fileprivate func appendWindows(at location: CGPoint, to result: inout [Window]) {
        if let window = self as? Window {
            if window.lifeStatus.isInhabited, (window.observedFrame ?? window.lastAppliedLayoutPhysicalRect)?.contains(location) == true {
                result.append(window)
            }
        } else if let accordion = self as? TilingContainer, accordion.layout == .accordion {
            // One place on the screen: its most recent window. The others only peek out by the accordion padding
            guard accordion.lastAppliedLayoutPhysicalRect?.contains(location) == true, let child = accordion.mostRecentInhabitedChild else { return }
            if let window = child as? Window {
                result.append(window)
            } else {
                child.appendWindows(at: location, to: &result)
            }
        } else {
            for child in children { child.appendWindows(at: location, to: &result) }
        }
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
