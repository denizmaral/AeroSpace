import AppKit
import Common

enum GlobalObserver {
    private static func onNotif(_ notification: Notification) {
        // Third line of defence against lock screen window. See: closedWindowsCache
        // Second and third lines of defence are technically needed only to avoid potential flickering
        if (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == lockScreenAppBundleId {
            return
        }
        let notifName = notification.name.rawValue
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let pid = app?.processIdentifier
        let bundleId = app?.bundleIdentifier
        Task.startUnstructured { @MainActor in
            // Normally known already: the list of the running apps changes before the notification is posted
            if notifName == NSWorkspace.didLaunchApplicationNotification.rawValue, let app { RunningApps.get(app) }
            FocusBorderController.shared.stackingMayHaveChanged()
            if !TrayMenuModel.shared.isEnabled { return }
            switch notifName {
                case NSWorkspace.activeSpaceDidChangeNotification.rawValue:
                    // The border belongs to the previous Space. The refresh session shows it again if needed
                    FocusBorderController.shared.hideAfterSpaceChange()
                    MacWindow.invalidateAllSentFrames()
                    MissionControl.exitIfStale()
                case NSWorkspace.didLaunchApplicationNotification.rawValue where bundleId == "com.apple.dock":
                    MissionControl.observe() // The Dock was relaunched
                case NSWorkspace.didWakeNotification.rawValue, NSApplication.didChangeScreenParametersNotification.rawValue:
                    MacWindow.invalidateAllSentFrames() // macOS may move windows around
                case NSWorkspace.didActivateApplicationNotification.rawValue:
                    // Self-healing: the user interacts with the app. Make sure that its windows are where they must be
                    if let pid {
                        MacWindow.invalidateSentFrames(pid: pid)
                        MacApp.allAppsMap[pid]?.refreshName()
                    }
                    MissionControl.exitIfStale()
                default:
                    break
            }
            if notifName == NSWorkspace.didActivateApplicationNotification.rawValue {
                scheduleCancellableCompleteRefreshSession(.globalObserver(notifName), optimisticallyPreLayoutWorkspaces: true)
            } else {
                scheduleCancellableCompleteRefreshSession(.globalObserver(notifName))
            }
        }
    }

    private static func onHideApp(_ notification: Notification) {
        let notifName = notification.name.rawValue
        Task.startUnstructured { @MainActor in
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try await runLightSession(.globalObserver(notifName), token) {
                if config.automaticallyUnhideMacosHiddenApps {
                    if let w = prevFocus?.windowOrNil,
                       w.macAppUnsafe.nsApp.isHidden,
                       // "Hide others" (cmd-alt-h) -> don't force focus
                       // "Hide app" (cmd-h) -> force focus
                       MacApp.allAppsMap.values.count(where: { $0.nsApp.isHidden }) == 1
                    {
                        // Force focus
                        _ = w.focusWindow()
                        w.nativeFocus()
                    }
                    for app in MacApp.allAppsMap.values {
                        app.nsApp.unhide()
                    }
                }
            }
        }
    }

    /// An app got or lost its Dock icon, was hidden or shown, or quit (see ``RunningApps``): a refresh session if it
    /// would see the change. NSWorkspace has no notification for the Dock icon, and the others may not be posted for
    /// an app without one (its utility window can be managed all the same)
    @MainActor
    private static func onAppChange(_ app: RunningApp, _ property: String) {
        // An app that is being launched is registered when it finished launching (didLaunchApplicationNotification)
        if MacApp.allAppsMap[app.pid] != nil || app.nsApp.activationPolicy == .regular && app.nsApp.isFinishedLaunching {
            scheduleCancellableCompleteRefreshSession(.globalObserver("NSRunningApplication.\(property)"))
        }
    }

    @MainActor
    static func initObserver() {
        RunningApps.onChange = onAppChange
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main, using: onHideApp)
        nc.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main, using: onNotif)
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: onNotif)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: onNotif)

        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            // todo reduce number of refreshSession in the callback
            //  resetManipulatedWithMouseIfPossible might call its own refreshSession
            //  The end of the callback calls refreshSession
            Task.startUnstructured { @MainActor in
                FocusBorderController.shared.stackingMayHaveChanged() // A click raises the window under the mouse
                FocusBorderController.shared.showAfterMouseDrag()
                try await resetManipulatedWithMouseIfPossible()
                let mouseLocation = mouseLocation
                let clickedMonitor = mouseLocation.monitorApproximation
                switch true {
                    // Detect clicks on desktop of different monitors
                    case clickedMonitor.visibleRect.contains(mouseLocation) && clickedMonitor.visibleWorkspace != globalFocus.workspace:
                        _ = try await runLightSession(.globalObserverLeftMouseUp, token) {
                            clickedMonitor.visibleWorkspace.focusWorkspace()
                        }
                    // Detect close button clicks for unfocused windows. Yes, kAXUIElementDestroyedNotification is that unreliable
                    //  And trigger new window detection that could be delayed due to mouseDown event
                    default:
                        scheduleCancellableCompleteRefreshSession(.globalObserverLeftMouseUp)
                }
            }
        }
    }
}
