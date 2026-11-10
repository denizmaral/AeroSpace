/// The last time when the native state of the windows of invisible workspaces was checked. See normalizeLayoutReason
@MainActor var lastInvisibleWindowsNativeStateCheck: ContinuousClock.Instant? = nil

@MainActor func normalizeLayoutReason() async throws {
    // Windows of invisible workspaces are hidden in the corner of the screen, their native state rarely changes. Saves
    // 2 AX calls per window per refresh session. They are checked:
    // - when AX notifies about a native state change (e.g. "Minimize All"), see refreshObs, or AeroSpace changes it
    // - when they are already in a native macOS state (the user can leave it)
    // - at most every 5 seconds, as a safety net
    // The timestamp is recorded before the checks: sessions are often canceled by newer events, a timestamp recorded
    // after the checks would never be recorded during bursts of events. Notified windows are checked anyway
    let now = ContinuousClock.now
    let checkInvisible = lastInvisibleWindowsNativeStateCheck.map { now - $0 >= .seconds(5) } ?? true
    if checkInvisible { lastInvisibleWindowsNativeStateCheck = now }
    for workspace in Workspace.all {
        let windows: [Window] = workspace.isVisible || checkInvisible
            ? workspace.allLeafWindowsRecursive
            : workspace.allLeafWindowsRecursive.filter { $0.layoutReason != .standard || $0.isNativeStateCheckRequested }
        if windows.isEmpty { continue }
        // Clear the requests before the AX reads: a notification during the reads requests a new check
        let requested = windows.filter(\.isNativeStateCheckRequested)
        for window in requested { window.isNativeStateCheckRequested = false }
        do {
            try await _normalizeLayoutReason(workspace: workspace, windows: windows)
        } catch {
            for window in requested { window.isNativeStateCheckRequested = true } // Not checked, e.g. the session is canceled
            throw error
        }
    }
    try await _normalizeLayoutReason(workspace: globalFocus.workspace, windows: macosMinimizedWindowsContainer.children.filterIsInstance(of: Window.self))
    try await validateStillPopups()
}

@MainActor private var popupRecheckTask: Task<(), any Error>? = nil

/// Some apps create windows that look like popups for a moment (e.g. a new Terminal window doesn't have its buttons
/// and the standard subrole yet). validateStillPopups runs in every complete refresh session, but nothing triggers the
/// next session until the user interacts with something, so the window stays untiled. Recheck shortly after
@MainActor func schedulePopupRecheck() {
    popupRecheckTask?.cancel() // Restart. Every new popup gets the whole schedule
    popupRecheckTask = Task.startUnstructured { @MainActor in
        for delay: Duration in [.milliseconds(300), .milliseconds(1200)] {
            try await Task.sleep(for: delay)
            if macosPopupWindowsContainer.children.isEmpty { return }
            scheduleCancellableCompleteRefreshSession(.popupRecheck)
        }
    }
}

@MainActor private func validateStillPopups() async throws {
    for node in macosPopupWindowsContainer.children {
        let popup = (node as! MacWindow)
        let windowLevel = try await popup.getWindowLevel(.cancellable)
        if try await popup.isWindowHeuristic(windowLevel, .cancellable) {
            let dwindleSplit = try await popup.relayoutWindowDeferringDwindleSplit(on: globalFocus.workspace, .cancellable)
            await runOnWindowDetected(ifConventional: popup)
            // After the callbacks, because they may move the window to another workspace
            popup.applyDwindleSplit(dwindleSplit)
        }
    }
}

@MainActor private func _normalizeLayoutReason(workspace: Workspace, windows: [Window]) async throws {
    let states = try await windows.mapConcurrently { try await $0.getMacosWindowNativeState(.cancellable) }
    for (window, state) in zip(windows, states) {
        let isMacosFullscreen = state == .nativeFullscreen
        let isMacosMinimized = state == .nativeMinimized
        let isMacosWindowOfHiddenApp = !isMacosFullscreen && !isMacosMinimized &&
            !config.automaticallyUnhideMacosHiddenApps && window.macAppUnsafe.nsApp.isHidden
        switch window.layoutReason {
            case .standard:
                guard let parent = window.windowParentCases else { continue }
                switch true {
                    case isMacosFullscreen:
                        window.enterMacosNativeState(workspace.macOsNativeFullscreenWindowsContainer, prevParentKind: parent.kind, adaptiveWeight: WEIGHT_DOESNT_MATTER)
                    case isMacosMinimized:
                        window.enterMacosNativeState(macosMinimizedWindowsContainer, prevParentKind: parent.kind, adaptiveWeight: 1)
                    case isMacosWindowOfHiddenApp:
                        window.enterMacosNativeState(workspace.macOsNativeHiddenAppsWindowsContainer, prevParentKind: parent.kind, adaptiveWeight: WEIGHT_DOESNT_MATTER)
                    default: break
                }
            case .macos(let prevParentKind):
                if !isMacosFullscreen && !isMacosMinimized && !isMacosWindowOfHiddenApp {
                    try await exitMacOsNativeUnconventionalState(window: window, prevParentKind: prevParentKind, workspace: workspace, .cancellable)
                }
        }
    }
}

@MainActor func exitMacOsNativeUnconventionalState(
    window: Window,
    prevParentKind: WindowParentCases.Kind,
    workspace: Workspace,
    _ cm: CancellationMode,
) async throws {
    window.layoutReason = .standard
    switch prevParentKind {
        case .floatingWindowsContainer:
            window.bindAsFloatingWindow(to: workspace)
        case .tilingContainer:
            // The same place as before the native state. A new place only if it's gone
            if !window.bindBackToTilingSlot(on: workspace) {
                try await window.relayoutWindow(on: workspace, cm, forceTile: true)
            }
        case .macosPopupWindowsContainer: // Since the window was minimized/fullscreened it was mistakenly detected as popup. Relayout the window
            try await window.relayoutWindow(on: workspace, cm)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
            // E.g. the macos-native-fullscreen command bound the window to the fullscreen container before the native
            // state was detected. The window may still have its place in the tiling tree
            if !window.bindBackToTilingSlot(on: workspace) {
                try await window.relayoutWindow(on: workspace, cm)
            }
    }
}
