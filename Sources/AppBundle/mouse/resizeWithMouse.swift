import AppKit
import Common

@MainActor
private var resizeWithMouseTask: Task<(), any Error>? = nil

func resizedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notif = notif as String
    let nativeWindowId = ax.containingNativeWindowId()
    let pid = ax.pid
    Task.startUnstructured { @MainActor in
        FocusBorderController.shared.stackingMayHaveChanged()
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        let window = nativeWindowId.flatMap { nativeWindowId in pid.flatMap { Window.get(byNativeId: nativeWindowId, pid: $0) } }
        // The window may be moved or resized by somebody else (the user, the app). See Window.setAxFrame
        window?.invalidateSentFrame()
        guard let window, try await isManipulatedWithMouse(window) else {
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }
        FocusBorderController.shared.hideForMouseDrag()
        resizeWithMouseTask?.cancel()
        resizeWithMouseTask = Task.startUnstructured {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
                try await resizeWithMouse(window)
            }
        }
    }
}

/// The mouse button was released
@MainActor
func resetManipulatedWithMouseIfPossible() async throws {
    if endManipulationWithMouse() {
        scheduleCancellableCompleteRefreshSession(.resetManipulatedWithMouse, optimisticallyPreLayoutWorkspaces: true)
    }
}

/// The window that was moved or resized with the mouse is laid out again, and the tiling trees are persisted again
/// (see `WindowPlacementStore.persistIfChanged`)
///
/// - Returns: false if no window was manipulated with the mouse
@MainActor
@discardableResult
func endManipulationWithMouse() -> Bool {
    guard currentlyManipulatedWithMouseWindowId != nil else { return false }
    currentlyManipulatedWithMouseWindowId = nil
    for workspace in Workspace.all {
        workspace.resetResizeWeightBeforeResizeRecursive()
    }
    return true
}

private let adaptiveWeightBeforeResizeWithMouseKey = TreeNodeUserDataKey<CGFloat>(key: "adaptiveWeightBeforeResizeWithMouseKey")
private let weightScaleBeforeResizeWithMouseKey = TreeNodeUserDataKey<CGFloat>(key: "weightScaleBeforeResizeWithMouseKey")

extension TilingContainer {
    /// Weight per pixel when the drag started. The weights change during the drag, the scale must not
    @MainActor
    fileprivate func getWeightScaleBeforeResize() -> CGFloat {
        getUserData(key: weightScaleBeforeResizeWithMouseKey)
            ?? pixelsToWeight(1).also { putUserData(key: weightScaleBeforeResizeWithMouseKey, data: $0) }
    }
}

/// The edges of the window that the user drags are moved to the mouse: the tiles next to them get bigger or smaller
@MainActor
func resizeWithMouse(_ window: Window) async throws {
    resetClosedWindowsCache()
    switch window.windowParentCases {
        case nil: return
        case .floatingWindowsContainer, .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
             .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Nothing to do for floating, or unconventional windows
        case .tilingContainer:
            guard let rect = try await window.getAxRect(.cancellable) else { return }
            guard let lastAppliedLayoutRect = window.lastAppliedLayoutPhysicalRect else { return }
            // Where the window was when the drag started (the layout leaves it alone while it's dragged). An edge that
            // is still there isn't dragged, also if it isn't at the edge of the tile: the window refuses the size of
            // its tile, or the layout moved it off a window that is bigger than its tile. A dragged edge takes the
            // edge of the tile with it
            let start = window.observedFrame ?? lastAppliedLayoutRect
            let (lParent, lOwnIndex, _) = window.closestParent(hasInhabitedChildrenInDirection: .left, withLayout: .tiles) ?? (nil, nil, nil)
            let (dParent, dOwnIndex, _) = window.closestParent(hasInhabitedChildrenInDirection: .down, withLayout: .tiles) ?? (nil, nil, nil)
            let (uParent, uOwnIndex, _) = window.closestParent(hasInhabitedChildrenInDirection: .up, withLayout: .tiles) ?? (nil, nil, nil)
            let (rParent, rOwnIndex, _) = window.closestParent(hasInhabitedChildrenInDirection: .right, withLayout: .tiles) ?? (nil, nil, nil)
            let table: [(CGFloat, CGFloat, TilingContainer?, Int?, Int?)] = [
                (start.minX - rect.minX, lastAppliedLayoutRect.minX - rect.minX, lParent, 0,                        lOwnIndex),               // Horizontal, to the left of the window
                (rect.maxY - start.maxY, rect.maxY - lastAppliedLayoutRect.maxY, dParent, dOwnIndex.map { $0 + 1 }, dParent?.children.count), // Vertical, to the down of the window
                (start.minY - rect.minY, lastAppliedLayoutRect.minY - rect.minY, uParent, 0,                        uOwnIndex),               // Vertical, to the up of the window
                (rect.maxX - start.maxX, rect.maxX - lastAppliedLayoutRect.maxX, rParent, rOwnIndex.map { $0 + 1 }, rParent?.children.count), // Horizontal, to the right of the window
            ]
            for (dragged, diff, parent, startIndex, untilIndex) in table {
                if let parent, let startIndex, let untilIndex, untilIndex - startIndex > 0 && abs(dragged) > 5 { // 5 pixels should be enough to fight with accumulated floating precision error
                    let orientation = parent.orientation

                    window.parentsWithSelf.lazy
                        .prefix(while: { $0 != parent })
                        .filter {
                            let parent = $0.parent as? TilingContainer
                            return parent?.orientation == orientation && parent?.layout == .tiles
                        }
                        .forEach { node in
                            // `diff` is in pixels, the weights are proportions (see TilingContainer.pixelsToWeight)
                            let scale = (node.parent as? TilingContainer)?.getWeightScaleBeforeResize() ?? 1
                            node.setWeight(orientation, node.getWeightBeforeResize(orientation) + diff * scale)
                        }
                    let inhabitedSiblings = (parent.children.slice(startIndex ..< untilIndex) ?? [])
                        .filter { $0.tilingTreeNodeCasesOrDie().isInhabited }
                    guard let siblingDiff = (diff * parent.getWeightScaleBeforeResize()).div(inhabitedSiblings.count) else { return }
                    for sibling in inhabitedSiblings {
                        sibling.setWeight(orientation, sibling.getWeightBeforeResize(orientation) - siblingDiff)
                    }
                }
            }
            currentlyManipulatedWithMouseWindowId = window.windowId
    }
}

extension TreeNode {
    @MainActor
    fileprivate func getWeightBeforeResize(_ orientation: Orientation) -> CGFloat {
        getUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
            ?? getWeight(orientation).also { putUserData(key: adaptiveWeightBeforeResizeWithMouseKey, data: $0) }
    }

    fileprivate func resetResizeWeightBeforeResizeRecursive() {
        cleanUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
        cleanUserData(key: weightScaleBeforeResizeWithMouseKey)
        for child in children {
            child.resetResizeWeightBeforeResizeRecursive()
        }
    }
}
