import AppKit
import Common

final class MacWindow: Window {
    let macApp: MacApp
    private var prevUnhiddenProportionalPositionInsideWorkspaceRect: CGPoint?

    @MainActor private init(
        _ id: OpaqueWindowId,
        _ actor: MacApp,
        lastFloatingSize: CGSize?,
        parent: NonLeafTreeNodeObject,
        adaptiveWeight: CGFloat,
        index: Int,
    ) {
        self.macApp = actor
        super.init(id: id, actor, lastFloatingSize: lastFloatingSize, parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static var allWindowsMap: [OpaqueWindowId: MacWindow] = [:]
    @MainActor static var allWindows: [MacWindow] { Array(allWindowsMap.values) }

    @MainActor
    @discardableResult
    static func getOrRegister(windowId: OpaqueWindowId, macApp: MacApp, lifeStatus: WindowLifeStatus = .alive) async throws -> MacWindow {
        if let existing = allWindowsMap[windowId] { return existing }
        let rect = try await macApp.getAxRect(windowId, .cancellable)
        // The window is known from the previous run (AeroSpace was restarted, or the window was invisible until now)
        let previousPlacement = WindowPlacementStore.previousPlacement(of: windowId, macApp)
        let workspace = previousPlacement.map { Workspace.get(byName: $0.workspace) }
            ?? (isStartup ? (rect?.center.monitorApproximation ?? mainMonitorInfo).visibleWorkspace : globalFocus.workspace)
        // A window that was tiling in the previous run is tiling again: the dialog heuristic may be wrong right now (the
        // subrole of a window of a hidden app or a minimized window is AXDialog, e.g. when AeroSpace restarts)
        let data = try await unbindAndGetBindingDataForNewWindow(
            windowId, macApp, workspace, window: nil, .cancellable, wasTiling: previousPlacement?.isFloating == false,
        )

        // atomic synchronous section
        if let existing = allWindowsMap[windowId] { return existing }
        let window = MacWindow(windowId, macApp, lastFloatingSize: rect?.size, parent: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        if let previousPlacement {
            WindowPlacementStore.markRestored(windowId, macApp)
            if previousPlacement.isFloating, window.parent is TilingContainer {
                window.bindAsFloatingWindow(to: workspace)
            }
        }
        window.lifeStatus = lifeStatus // Invisible windows (e.g. on other macOS Spaces) must not split other windows
        allWindowsMap[windowId] = window
        if case .macosPopupWindowsContainer = window.windowParentCases { schedulePopupRecheck() }
        let dwindleSplit = window.captureDwindleSplit()
        // E.g. the session is canceled, or the closed windows cache is restored. Later splits must not wait for it
        defer { dwindleSplit?.discard() }

        try await debugWindowsIfRecording(window, .cancellable)
        if try await !restoreClosedWindowsCacheIfNeeded(newlyDetectedWindow: window) {
            await runOnWindowDetected(ifConventional: window)
            // After the callbacks, because they may move the window to another workspace
            window.applyDwindleSplit(dwindleSplit)
        }
        return window
    }

    // var description: String {
    //     let description = [
    //         ("title", title),
    //         ("role", axWindow.get(Ax.roleAttr)),
    //         ("subrole", axWindow.get(Ax.subroleAttr)),
    //         ("identifier", axWindow.get(Ax.identifierAttr)),
    //         ("modal", axWindow.get(Ax.modalAttr).map { String($0) } ?? ""),
    //         ("windowId", String(windowId)),
    //     ].map { "\($0.0): '\(String(describing: $0.1))'" }.joined(separator: ", ")
    //     return "Window(\(description))"
    // }

    func isWindowHeuristic(_ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool { // todo cache
        try await macApp.isWindowHeuristic(windowId, windowLevel, cm)
    }

    func isDialogHeuristic(_ windowLevel: MacOsWindowLevel?, _ cm: CancellationMode) async throws -> Bool { // todo cache
        try await macApp.isDialogHeuristic(windowId, windowLevel, cm)
    }

    func dumpAxInfo(_ cm: CancellationMode) async throws -> [String: Json] {
        try await macApp.dumpWindowAxInfo(windowId: windowId, cm)
    }

    @MainActor func getWindowLevel(_ cm: CancellationMode) async throws -> MacOsWindowLevel? {
        try await macApp.getWindowLevel(windowId, cm)
    }

    @MainActor func setNativeFullscreen(_ value: Bool) {
        invalidateSentFrame() // macOS changes the frame. Also, the pending frame job is canceled
        isNativeStateCheckRequested = true
        macApp.setNativeFullscreen(windowId, value)
    }

    @MainActor func setNativeMinimized(_ value: Bool) {
        invalidateSentFrame() // The pending frame job is canceled
        isNativeStateCheckRequested = true
        macApp.setNativeMinimized(windowId, value)
    }

    /// See ``Window/setAxFrame(_:_:)``
    @MainActor static func invalidateAllSentFrames() {
        for window in allWindowsMap.values { window.invalidateSentFrame() }
    }

    /// See ``Window/setAxFrame(_:_:)``
    @MainActor static func invalidateSentFrames(pid: pid_t) {
        for window in allWindowsMap.values where window.macApp.nsApp.processIdentifier == pid {
            window.invalidateSentFrame()
        }
    }

    // skipClosedWindowsCache is an optimization when it's definitely not necessary to cache closed window.
    //                        If you are unsure, it's better to pass `false`
    @MainActor
    func garbageCollect(skipClosedWindowsCache: Bool) {
        if MacWindow.allWindowsMap.removeValue(forKey: windowId) == nil {
            return
        }
        if !skipClosedWindowsCache { cacheClosedWindowIfNeeded() }
        let parent = unbindAsClosed().parent
        let deadWindowWorkspace = parent.nodeWorkspace
        let focus = globalFocus
        if let deadWindowWorkspace, deadWindowWorkspace == focus.workspace ||
            deadWindowWorkspace == prevFocusedWorkspace && prevFocusedWorkspaceDate.distance(to: .now) < 1
        {
            switch parent.cases {
                case .tilingContainer, .floatingWindowsContainer, .macosHiddenAppsWindowsContainer, .macosFullscreenWindowsContainer:
                    let deadWindowFocus = deadWindowWorkspace.toLiveFocus()
                    _ = setFocus(to: deadWindowFocus)
                    // Guard against "Apple Reminders popup" bug: AeroSpace issue #201
                    if focus.windowOrNil?.app.pid != app.pid {
                        // Force focus to fix macOS annoyance with focused apps without windows.
                        //   AeroSpace issue #65
                        deadWindowFocus.windowOrNil?.nativeFocus()
                    }
                case .macosPopupWindowsContainer, // Don't switch back on popup destruction
                     .workspace, // Workspace is invalid parent for windows
                     .monitor, // Monitor is invalid parent for windows
                     .workspacesContainer, // WorkspacesContainer is invalid parent for windows
                     .macosMinimizedWindowsContainer: // Don't switch back on minimized windows destruction
                    break
            }
        }
    }

    override func getTitle(_ cm: CancellationMode) async throws -> String { try await macApp.getAxTitle(windowId, cm) ?? "" }

    override func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { try await macApp.isMacosNativeFullscreen(windowId, cm) == true }
    override func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { try await macApp.isMacosNativeMinimized(windowId, cm) == true }
    override func getMacosWindowNativeState(_ cm: CancellationMode) async throws -> MacosWindowNativeState {
        try await macApp.getMacosWindowNativeState(windowId, cm) ?? .normal
    }

    @MainActor override func nativeFocus() {
        macApp.nativeFocus(windowId)
    }

    override func closeAxWindow() {
        garbageCollect(skipClosedWindowsCache: true)
        macApp.closeAndUnregisterAxWindow(windowId)
    }

    // todo it's part of the window layout and should be moved to layoutRecursive.swift
    @MainActor
    func hideInCorner(_ corner: OptimalHideCorner) async throws {
        guard let nodeMonitorInfo else { return }
        // Don't accidentally override prevUnhiddenEmulationPosition in case of subsequent `hideInCorner` calls
        if !isHiddenInCorner {
            guard let windowRect = try await getAxRect(.cancellable) else { return }
            // Check for isHiddenInCorner for the second time because of the suspension point above
            if !isHiddenInCorner {
                let topLeftCorner = windowRect.topLeftCorner
                let monitorRect = windowRect.center.monitorApproximation.rect // Similar to layoutFloatingWindow. Non idempotent
                let absolutePoint = topLeftCorner - monitorRect.topLeftCorner
                prevUnhiddenProportionalPositionInsideWorkspaceRect =
                    CGPoint(x: absolutePoint.x / monitorRect.width, y: absolutePoint.y / monitorRect.height)
                if isFloating {
                    lastFloatingSize = windowRect.size
                }
            }
        }
        let p: CGPoint
        switch corner {
            case .bottomLeftCorner:
                guard let s = try await getAxSize(.cancellable) else { fallthrough }
                // Zoom will jump off if you do one pixel offset AeroSpace issue #527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = macApp.appId == .zoom ? .zero : CGPoint(x: 1, y: -1)
                p = nodeMonitorInfo.visibleRect.bottomLeftCorner + onePixelOffset + CGPoint(x: -s.width, y: 0)
            case .bottomRightCorner:
                // Zoom will jump off if you do one pixel offset AeroSpace issue #527
                // todo this ad hoc won't be necessary once I implement optimization suggested by Zalim
                let onePixelOffset = macApp.appId == .zoom ? .zero : CGPoint(x: 1, y: 1)
                p = nodeMonitorInfo.visibleRect.bottomRightCorner - onePixelOffset
        }
        setAxFrame(p, nil, readBack: false) // Nothing on the screen deals with it until it's shown again
    }

    @MainActor
    func unhideFromCorner() {
        guard let prevUnhiddenProportionalPositionInsideWorkspaceRect else { return }
        guard let nodeWorkspace else { return } // hiding only makes sense for workspace windows
        guard let parent else { return }

        switch getChildParentRelation(child: self, parent: parent) {
            // Just a small optimization to avoid unnecessary AX calls for non floating windows
            // Tiling windows should be unhidden with layoutRecursive anyway
            case .floatingWindow:
                let workspaceRect = nodeWorkspace.workspaceMonitorInfo.rect
                var newX = workspaceRect.topLeftX + workspaceRect.width * prevUnhiddenProportionalPositionInsideWorkspaceRect.x
                var newY = workspaceRect.topLeftY + workspaceRect.height * prevUnhiddenProportionalPositionInsideWorkspaceRect.y
                // todo we probably should replace lastFloatingSize with proper floating window sizing
                // AeroSpace issue #1519
                let windowWidth = lastFloatingSize?.width ?? 0
                let windowHeight = lastFloatingSize?.height ?? 0
                newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
                newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

                setAxFrame(CGPoint(x: newX, y: newY), nil)
            case .macosNativeFullscreenWindow, .macosNativeHiddenAppWindow, .macosNativeMinimizedWindow,
                 .macosPopupWindow, .tiling, .rootTilingContainer, .shimContainerRelation: break
        }

        self.prevUnhiddenProportionalPositionInsideWorkspaceRect = nil
    }

    override var isHiddenInCorner: Bool {
        prevUnhiddenProportionalPositionInsideWorkspaceRect != nil
    }

    override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? {
        try await macApp.getAxSize(windowId, cm)
    }

    override func sendAxFrame(_ topLeft: CGPoint?, _ size: CGSize?, readBack: UInt?) {
        macApp.setAxFrame(windowId, topLeft, size, readBack: readBack)
    }

    override func getAxRect(_ cm: CancellationMode) async throws -> Rect? {
        try await macApp.getAxRect(windowId, cm)
    }
}

extension Window {
    @MainActor
    func relayoutWindow(on workspace: Workspace, _ cm: CancellationMode, forceTile: Bool = false) async throws {
        applyDwindleSplit(try await relayoutWindowDeferringDwindleSplit(on: workspace, cm, forceTile: forceTile))
    }

    /// The caller is responsible for applying or discarding the returned split (see ``DwindleSplit``)
    @MainActor
    func relayoutWindowDeferringDwindleSplit(on workspace: Workspace, _ cm: CancellationMode, forceTile: Bool = false) async throws -> DwindleSplit? {
        let data = forceTile
            ? unbindAndGetBindingDataForNewTilingWindow(workspace, window: self)
            : try await unbindAndGetBindingDataForNewWindow(self.asMacWindow().windowId, self.asMacWindow().macApp, workspace, window: self, cm)
        bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        return captureDwindleSplit()
    }

    /// Binds the window to the workspace the same way as newly detected tiling windows are bound
    @MainActor
    func bindAsNewTilingWindow(to workspace: Workspace) {
        let data = unbindAndGetBindingDataForNewTilingWindow(workspace, window: self)
        bind(to: data.parent, adaptiveWeight: data.adaptiveWeight, index: data.index)
        applyDwindleSplit(captureDwindleSplit())
    }
}

// The function is private because it's unsafe. It leaves the window in unbound state
/// `wasTiling`: the window is known to be a tiling window, a dialog verdict of the heuristic is ignored
@MainActor
private func unbindAndGetBindingDataForNewWindow(
    _ windowId: OpaqueWindowId,
    _ macApp: MacApp,
    _ workspace: Workspace,
    window: Window?,
    _ cm: CancellationMode,
    wasTiling: Bool = false,
) async throws -> BindingData {
    let windowLevel = try await macApp.getWindowLevel(windowId, cm)
    return switch try await macApp.getAxUiElementWindowType(windowId, windowLevel, cm) {
        case .popup: BindingData(parent: macosPopupWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        case .dialog where !wasTiling: BindingData(parent: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        case .dialog, .window: unbindAndGetBindingDataForNewTilingWindow(workspace, window: window)
    }
}

// The function is private because it's unsafe. It leaves the window in unbound state
@MainActor
private func unbindAndGetBindingDataForNewTilingWindow(_ workspace: Workspace, window: Window?) -> BindingData {
    window?.unbindFromParent() // It's important to unbind to get correct data from below
    if let (tilingParent, index) = workspace.newTilingWindowAnchor?.nearestAliveTilingParent() {
        return BindingData(parent: tilingParent, adaptiveWeight: WEIGHT_AUTO, index: index + 1)
    } else {
        return BindingData(
            parent: workspace.rootTilingContainer,
            adaptiveWeight: WEIGHT_AUTO,
            index: INDEX_BIND_LAST,
        )
    }
}

@MainActor
func runOnWindowDetected(ifConventional window: Window) async {
    switch window.windowParentCases {
        case .tilingContainer, .floatingWindowsContainer, .macosMinimizedWindowsContainer,
             .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer:
            let layout = global_layoutForNextDetectedWindow
            global_layoutForNextDetectedWindow = nil
            defer {
                if let layout {
                    await LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [layout]))
                        .run(.defaultEnv.withWindowId(window.windowId), .emptyStdin)
                }
            }
            if let layout {
                await LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [layout]))
                    .run(.defaultEnv.withWindowId(window.windowId), .emptyStdin)
            }
            _ = await onWindowDetected(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, window)
        case .macosPopupWindowsContainer, nil:
            break
    }
}

@MainActor
func onWindowDetected(_ env: CmdEnv, _ io: CmdIo, _ window: Window) async -> Int32ExitCode {
    broadcastEvent(.windowDetected(
        windowId: window.windowId,
        workspace: window.nodeWorkspace?.name,
        appBundleId: window.app.rawAppBundleId,
        appName: window.app.name,
    ))
    var lastExitCode = Int32ExitCode.succ
    for callback in config.onWindowDetected where await callback.matcher.matches(window) {
        // A move by a rule isn't a move by the user: the app isn't remembered on that workspace
        lastExitCode = await WindowRuleContext.$isRunning.withValue(true) { await callback.run.run(env.withWindowId(window.windowId), io) }
        if !callback.checkFurtherCallbacks {
            return lastExitCode
        }
    }
    return lastExitCode
}
