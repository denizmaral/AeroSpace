import AppKit
import Common

@MainActor private var focusFollowsMouseMonitor: Any? = nil
@MainActor private var focusFollowsTask: Task<(), any Error>? = nil
@MainActor private var mouseTracker = FocusFollowsMouseTracker()

@MainActor func syncFocusFollowsMouse(_ config: Config) {
    if config.focusFollowsMouse == (focusFollowsMouseMonitor != nil) {
        return
    }

    if !config.focusFollowsMouse {
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
        // MarSpace's own windows (the settings window, the menu) are above the windows that it manages
        let windows = isOverOwnWindow(event.locationInWindow) ? [] : location.monitorApproximation.visibleWorkspace.windowsUnderMouse(location)
        let move = mouseTracker.mouseMoved(
            over: windows, focused: globalFocus.windowOrNil, focusChanges: focusChangesByOtherMeans, now: .now,
            frontmost: { frontmostWindow(of: windows) },
        )
        if move != .stay { focusLogger.info("ffm \(String(describing: move), privacy: .public) over \(windows.map(\.windowId.description).joined(separator: ","), privacy: .public)") }
        switch move {
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
            let target = mouseTracker.checked(real: real, focused: globalFocus.windowOrNil, focusChanges: focusChangesByOtherMeans, now: .now)
            focusLogger.info("ffm checked: real \(real?.windowId.description ?? "nil", privacy: .public), focused \(globalFocus.windowOrNil?.windowId.description ?? "nil", privacy: .public), focus changes \(focusChangesByOtherMeans), focuses \(target?.windowId.description ?? "nothing", privacy: .public)")
            guard let target else { return }
            let focusChanges = focusChangesByOtherMeans
            // Not canceled by later mouse moves: the tracker took the window as the one under the mouse, it wouldn't try again
            Task.startUnstructured { @MainActor in
                try await runLightSession(.focusFollowsMouse, token) {
                    focusFollowsMouse(to: target, ifTheFocusDidntChangeSince: focusChanges)
                }
            }
        }
    }
}

/// The session starts with the macOS focus, which may have changed since the check: e.g. an app that was just launched
/// focused its window (moved to another workspace by its window rule). The later action wins
@MainActor func focusFollowsMouse(to window: Window, ifTheFocusDidntChangeSince focusChanges: UInt) {
    guard focusChangesByOtherMeans == focusChanges else {
        focusLogger.info("ffm yields to the focus of \(globalFocus.windowOrNil?.windowId.description ?? "nil", privacy: .public)")
        return
    }
    _ = window.focusWindow()
    window.nativeFocus()
}

/// The windows under the mouse changed without the mouse crossing a window border: another workspace is shown, Mission
/// Control was closed. The window under the mouse must not be focused until the mouse enters another window
@MainActor func resetFocusFollowsMouse() {
    focusFollowsTask?.cancel()
    mouseTracker.takeTheNextWindowsAsTheyAre()
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
    /// See ``takeTheNextWindowsAsTheyAre()``
    private var isBaselineNeeded = false

    /// - Parameter windows: the windows under the mouse right now. The one on top (`top`, if known) is not focused until
    ///   the mouse enters another window
    init(windowsUnderMouse windows: [Window] = [], top: Window? = nil) {
        windowIds = Set(windows.map(\.windowId))
        realWindow = top
        isRealWindowKnown = top != nil || windows.isEmpty
    }

    /// The next mouse move takes the windows under the mouse as they are, without focusing: they changed without the mouse
    /// crossing a window border (e.g. another workspace is shown while the mouse rests)
    mutating func takeTheNextWindowsAsTheyAre() {
        isBaselineNeeded = true
        recheckAt = nil
    }

    /// - Parameter windows: the windows whose observed frames contain the mouse location
    /// - Parameter frontmost: the frontmost of them in the stacking of the window server, nil if unknown. Asked only where
    ///   windows overlap, when the mouse enters there
    /// - Parameter focusChanges: ``focusChangesByOtherMeans``
    mutating func mouseMoved(over windows: [Window], focused: Window?, focusChanges: UInt, now: ContinuousClock.Instant, frontmost: () -> Window?) -> MouseMove {
        if isBaselineNeeded {
            isBaselineNeeded = false
            windowIds = Set(windows.map(\.windowId))
            let top = windows.count == 1 ? windows.first : frontmost()
            realWindow = top
            isRealWindowKnown = top != nil || windows.isEmpty
            return .leave
        }
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
        // Not assumed to be the focused window: the focus can be ahead of the stacking (a focus that is still applied, an
        // app that is being activated) or behind it (a window that stays on top without being focused)
        let top = windows.count == 1 ? windows.first : frontmost()
        if let top, top == focused || isRealWindowKnown && top === realWindow {
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
        // Checked again on the next mouse moves while the check doesn't find one of the windows under the mouse: a menu over
        // the window (it's focused when the menu is closed), or the edge of a window next to it (macOS hit tests a margin
        // around a window for resizing: the first mouse position after leaving a window can still be in it)
        recheckAt = real.map { windowIds.contains($0.windowId) } == true ? nil : now + Self.recheckInterval
        guard let real, real != focused, previous.map({ real !== $0 }) ?? true, focusChanges == focusChangesAtCheckStart,
              Self.mayFocus(real, from: focused)
        else { return nil }
        return real
    }

    /// A focused floating window keeps the focus over the tiling windows behind it: focusing a window raises it in macOS
    /// (there is no focus without raising), the floating window would disappear behind it. E.g. the mouse crosses Mail,
    /// which fills the workspace, on its way from the Dock to a small floating window in front of it. A click or a shortcut
    /// focuses the tiling window. Like Hyprland's `float_switch_override_focus = 0`, only where the windows overlap
    static func mayFocus(_ window: Window, from focused: Window?) -> Bool {
        guard let focused, focused.isFloating, !window.isFloating,
              let floatingFrame = focused.observedFrame, let frame = window.observedFrame
        else { return true }
        return floatingFrame.intersection(frame) == nil
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

/// The frontmost of the windows in the stacking of the window server. One query, no accessibility calls
@MainActor
private func frontmostWindow(of windows: [Window]) -> Window? {
    var byNativeId: [Int: Window] = [:]
    for case let window as MacWindow in windows {
        if let nativeWindowId = window.macApp.nativeWindowId(of: window.windowId) { byNativeId[Int(nativeWindowId)] = window }
    }
    let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for info in infos { // Front to back
        if let number = info[kCGWindowNumber as String] as? Int, let window = byNativeId[number] { return window }
    }
    return nil
}

/// A window of MarSpace (the settings window, the menu) is the front most window under the mouse. One behind other windows
/// doesn't count. The window server is asked only when one of them is under the mouse at all
/// - Parameter cocoaLocation: in screen coordinates of AppKit (the origin at the bottom left)
@MainActor
private func isOverOwnWindow(_ cocoaLocation: CGPoint) -> Bool {
    let own = Set(NSApp.windows.lazy // Not the focus border: it ignores the mouse
        .filter { $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(cocoaLocation) }
        .map(\.windowNumber))
    guard !own.isEmpty else { return false }
    let location = cocoaLocation.withYAxisFlipped
    let ownPid = ProcessInfo.processInfo.processIdentifier
    let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for info in infos { // Front to back
        guard let number = info[kCGWindowNumber as String] as? Int,
              let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
              bounds.contains(location)
        else { continue }
        if own.contains(number) { return true }
        // Another app's window in the normal layer is in front. Other layers (the menu bar, the Dock) and MarSpace's
        // other windows (the focus border) don't decide
        if info[kCGWindowOwnerPID as String] as? Int32 != ownPid, info[kCGWindowLayer as String] as? Int == 0 { return false }
    }
    return true // Not in the list (yet): as before, MarSpace's window is under the mouse
}
