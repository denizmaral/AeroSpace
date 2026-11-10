/// The last time when the native state of the windows of invisible workspaces was checked. See normalizeLayoutReason
@MainActor var lastInvisibleWindowsNativeStateCheck: ContinuousClock.Instant? = nil

@MainActor func normalizeLayoutReason() async throws {
    // Windows of invisible workspaces are hidden in the corner of the screen, their native state rarely changes. Saves
    // 2 AX calls per window per refresh session. They are checked:
    // - when AX notifies about a native state change (e.g. "Minimize All"), see refreshObs, or AeroSpace changes it
    // - when they are already in a native macOS state (the user can leave it)
    // - at most every 5 seconds, as a safety net
    let start = ContinuousClock.now
    let checkInvisible = lastInvisibleWindowsNativeStateCheck.map { start - $0 >= .seconds(5) } ?? true
    for workspace in Workspace.all {
        let windows: [Window] = workspace.isVisible || checkInvisible
            ? workspace.allLeafWindowsRecursive
            : workspace.allLeafWindowsRecursive.filter { $0.layoutReason != .standard || $0.isNativeStateCheckRequested }
        if windows.isEmpty { continue }
        try await _normalizeLayoutReason(workspace: workspace, windows: windows)
        for window in windows { window.isNativeStateCheckRequested = false }
    }
    // After the checks: the session may be canceled in the middle
    if checkInvisible { lastInvisibleWindowsNativeStateCheck = start }
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
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
                    case isMacosMinimized:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                    case isMacosWindowOfHiddenApp:
                        window.layoutReason = .macos(prevParentKind: parent.kind)
                        window.bind(to: workspace.macOsNativeHiddenAppsWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
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
            try await window.relayoutWindow(on: workspace, cm, forceTile: true)
        case .macosPopupWindowsContainer: // Since the window was minimized/fullscreened it was mistakenly detected as popup. Relayout the window
            try await window.relayoutWindow(on: workspace, cm)
        case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer: // wtf case, should never be possible. But If encounter it, let's just re-layout window
            try await window.relayoutWindow(on: workspace, cm)
    }
}
