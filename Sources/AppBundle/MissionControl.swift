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

    private static var exitFallbackTask: Task<(), any Error>? = nil
    private static var activeSince: ContinuousClock.Instant = .now

    /// App activation or Space change while Mission Control is shown means that it was closed. Events right after it was
    /// shown are ignored (Mission Control itself may cause them)
    static func exitIfStale() {
        if isActive && ContinuousClock.now - activeSince > .milliseconds(500) { exit() }
    }

    fileprivate static func handle(_ notification: String) {
        if notification == exitNotification {
            exit()
            return
        }
        isActive = true
        activeSince = .now
        FocusBorderController.shared.hide()
        // Fallback in case the exit notification is missed. Mission Control is never shown for a minute
        exitFallbackTask?.cancel()
        exitFallbackTask = Task.startUnstructured { @MainActor in
            try await Task.sleep(for: .seconds(60))
            exit()
        }
    }

    /// Also called when an app is activated or the Space changes (Mission Control is closed by then). A fallback in
    /// case the exit notification is missed: otherwise, the focus border and focus-follows-mouse would stay off
    static func exit() {
        guard isActive else { return }
        isActive = false
        exitFallbackTask?.cancel()
        exitFallbackTask = nil
        // The mouse stopped over some window. Don't focus it until the mouse enters another window
        resetFocusFollowsMouse()
        scheduleCancellableCompleteRefreshSession(.globalObserver(exitNotification)) // Shows the focus border again
    }
}

private func missionControlObs(_: AXObserver, _: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notification = notif as String
    Task.startUnstructured { @MainActor in MissionControl.handle(notification) }
}
