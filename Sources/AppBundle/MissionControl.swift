import AppKit
import Common

/// Mission Control (Exposé) state, observed via the accessibility notifications of the Dock (the same approach as
/// yabai). Event driven, no polling.
///
/// While Mission Control is shown, the focus border is hidden and focus-follows-mouse is suspended: the mouse moves over
/// window thumbnails, not over the windows themselves.
@MainActor
enum MissionControl {
    private(set) static var isActive = false
    private static var observer: AXObserver? = nil
    private static var observedDockPid: pid_t? = nil

    private static let exitNotification = "AXExposeExit"
    private static let notifications = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop", exitNotification]

    /// Idempotent. Call it on startup and when the Dock is relaunched
    static func observe() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              dock.processIdentifier != observedDockPid,
              let newObserver = unsafe AXObserver.new(dock.processIdentifier, missionControlObs)
        else { return }
        let dockAx = AXUIElementCreateApplication(dock.processIdentifier)
        for notification in notifications {
            _ = AXObserverAddNotification(newObserver, dockAx, notification as CFString, nil)
        }
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .defaultMode)
        observer = newObserver
        observedDockPid = dock.processIdentifier
        isActive = false
    }

    fileprivate static func handle(_ notification: String) {
        let wasActive = isActive
        isActive = notification != exitNotification
        if isActive {
            FocusBorderController.shared.hide()
        } else if wasActive {
            // The mouse stopped over some window. Don't focus it until the mouse enters another window
            resetFocusFollowsMouse()
            scheduleCancellableCompleteRefreshSession(.globalObserver(notification)) // Shows the focus border again
        }
    }
}

private func missionControlObs(_: AXObserver, _: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notification = notif as String
    Task.startUnstructured { @MainActor in MissionControl.handle(notification) }
}
