import AppKit
import Common

// Minimum sizes of windows
//
// There is no accessibility API to query the minimum size of a window, so AeroSpace learns it: when an app refuses to
// shrink its window to the size that the layout asked for (the window stays bigger), the observed size is its minimum.
//
// The tiles layout then gives every window at least its minimum size (see fitLengths). When the minimums don't fit
// into the container at all (e.g. two windows of 1000pt and 960pt minimum width on a 1800pt wide screen), the container
// is rendered as an accordion. The tree itself isn't changed, so it's rendered as tiles again once the windows fit.

enum MinimumSizeCheckResult: Equatable {
    /// The window has the size that the layout asked for (or it can't be checked)
    case fits
    /// The window refused the size twice. `learnedMinimumSize` is updated
    case learned
    /// The layout kept changing during the check
    case inconclusive
}

extension Window {
    /// Distinguishes rounding (e.g. Terminal snaps its size to the character grid) from refusing the size
    private static let minimumSizeTolerance: CGFloat = 8
    static let minimumSizeConfirmationDelay: Duration = .milliseconds(400)
    static let minimumSizeCooldown: Duration = .seconds(2)

    /// Call it after kAXResizedNotification that isn't caused by the mouse. See ``checkMinimumSize(confirmationDelay:)``.
    /// Requests that arrive while a check (or its cooldown) runs aren't lost: they cause one more check afterwards
    @MainActor
    func scheduleMinimumSizeCheck(
        confirmationDelay: Duration = minimumSizeConfirmationDelay,
        cooldown: Duration = minimumSizeCooldown,
    ) {
        if minimumSizeCheckTask != nil {
            isMinimumSizeRecheckRequested = true
            return
        }
        minimumSizeCheckTask = Task.startUnstructured { @MainActor [weak self] in
            defer { self?.minimumSizeCheckTask = nil }
            while let self {
                isMinimumSizeRecheckRequested = false
                switch try await checkMinimumSize(confirmationDelay: confirmationDelay) {
                    case .learned:
                        // Don't recheck right away: the layout isn't updated yet (the refresh session is debounced), the
                        // check would send the refused frame again. The new layout runs the requested check instead
                        if isMinimumSizeRecheckRequested { isMinimumSizeRecheckAfterLayoutRequested = true }
                        scheduleCancellableCompleteRefreshSession(.minimumSizeLearned)
                        return
                    case .inconclusive:
                        // E.g. the layout keeps changing. Don't spend AX calls on the window for a while
                        try await Task.sleep(for: cooldown)
                        if !isMinimumSizeRecheckRequested { return }
                    case .fits:
                        if !isMinimumSizeRecheckRequested { return }
                }
            }
        }
    }

    /// Called at the end of the layout of the window's workspace: the new frame is sent by then (and the AX read of the
    /// check is queued after it). See ``forgetMinimumSizeAndRecheckAfterLayout()``
    @MainActor
    func runMinimumSizeCheckRequestedAfterLayout() {
        guard isMinimumSizeRecheckAfterLayoutRequested, minimumSizeCheckableRect != nil else { return }
        isMinimumSizeRecheckAfterLayoutRequested = false
        scheduleMinimumSizeCheck()
    }

    /// The window must be bigger than the layout asked for twice: the requested frame is sent again in between. A
    /// single observation may be an animation, a late frame of an asynchronous app (e.g. Electron) or a resize
    /// initiated by the app itself. The bigger of the two refused sizes is learned (some apps jitter).
    ///
    /// Every await is followed by the synchronous revalidation of the requested rect: the layout may change it, or the
    /// workspace may become invisible meanwhile. A frame is sent only right after the validation
    @MainActor
    func checkMinimumSize(confirmationDelay: Duration) async throws -> MinimumSizeCheckResult {
        var previous: (requested: Rect, refused: CGSize)? = nil
        for _ in 0 ..< 4 {
            guard let requested = minimumSizeCheckableRect else { return .fits }
            guard let actual = try? await getAxSize(.cancellable) else { return .fits }
            guard minimumSizeCheckableRect == requested else { // The layout has changed meanwhile. Read again
                previous = nil
                continue
            }
            forgetMinimumSizeIfSmaller(actual)
            guard let refused = refusedSize(actual, requested) else { return .fits }
            if let previous, previous.requested == requested {
                // The dimensions that were refused both times by (almost) the same size. Some apps jitter by a few
                // points, the bigger size is learned. Very different sizes mean that one of them is a late frame
                let width = Self.refusedBothTimes(previous.refused.width, refused.width)
                let height = Self.refusedBothTimes(previous.refused.height, refused.height)
                if width > 0 || height > 0 {
                    learnedMinimumSize = CGSize(width: max(learnedMinimumSize.width, width), height: max(learnedMinimumSize.height, height))
                    learnedMinimumSizeWorkspace = nodeWorkspace?.name
                    return .learned
                }
            }
            previous = (requested, refused)
            invalidateSentFrame()
            setAxFrame(requested.topLeftCorner, CGSize(width: requested.width, height: requested.height))
            try await Task.sleep(for: confirmationDelay)
        }
        return .inconclusive
    }

    /// The learned minimum size. Zero if unknown
    @MainActor
    var effectiveMinimumSize: CGSize { learnedMinimumSize }

    /// The minimum size of a window may change (e.g. its sidebar is hidden), but the layout never gives the window
    /// less than its learned minimum, so a smaller minimum can't be observed. Moving the window to another workspace
    /// forgets the learned minimum (see Window.bind)
    @MainActor
    func forgetMinimumSize() {
        learnedMinimumSize = .zero
        learnedMinimumSizeWorkspace = nil
    }

    /// Explicit sizing by the user (resize, balance-sizes, the end of a mouse drag) forgets the learned minimum, and
    /// checks the window again after the next layout of its workspace (see ``runMinimumSizeCheckRequestedAfterLayout()``):
    /// if the minimum is still real, it's learned again. A window at its minimum doesn't necessarily post
    /// kAXResizedNotification when it refuses a smaller size
    @MainActor
    func forgetMinimumSizeAndRecheckAfterLayout() {
        guard learnedMinimumSize != .zero else { return }
        forgetMinimumSize()
        isMinimumSizeRecheckAfterLayoutRequested = true
    }

    /// The rect that the layout asked for, if the window can be checked: a tiling window on a visible workspace that
    /// isn't dragged with the mouse. Windows of invisible workspaces are hidden in the corner, only their position is sent
    @MainActor
    private var minimumSizeCheckableRect: Rect? {
        guard case .tilingContainer = windowParentCases,
              !isFullscreen,
              windowId != currentlyManipulatedWithMouseWindowId,
              nodeWorkspace?.isVisible == true
        else { return nil }
        return lastAppliedLayoutPhysicalRect
    }

    /// The size if both observations refused the dimension by (almost) the same size, otherwise 0
    private static func refusedBothTimes(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
        first > 0 && second > 0 && abs(first - second) <= 2 * minimumSizeTolerance ? max(first, second) : 0
    }

    /// The window is smaller than its learned minimum (e.g. resized by the app itself). The minimum is outdated
    @MainActor
    private func forgetMinimumSizeIfSmaller(_ actual: CGSize) {
        let minimumSize = effectiveMinimumSize
        if minimumSize.width > 0 && actual.width + Self.minimumSizeTolerance < minimumSize.width {
            learnedMinimumSize.width = 0
        }
        if minimumSize.height > 0 && actual.height + Self.minimumSizeTolerance < minimumSize.height {
            learnedMinimumSize.height = 0
        }
    }

    /// Per dimension: the actual size if the window is bigger than requested (beyond the tolerance), otherwise 0.
    /// nil if the window fits
    private func refusedSize(_ actual: CGSize, _ requested: Rect) -> CGSize? {
        let refused = CGSize(
            width: actual.width > requested.width + Self.minimumSizeTolerance ? actual.width : 0,
            height: actual.height > requested.height + Self.minimumSizeTolerance ? actual.height : 0,
        )
        return refused == .zero ? nil : refused
    }
}

extension TreeNode {
    /// The minimum length of the tiling node along the orientation. 0 if unknown
    @MainActor
    func minimumLength(_ orientation: Orientation) -> CGFloat {
        switch tilingTreeNodeCasesOrDie() {
            case .window(let window):
                let minimumSize = window.effectiveMinimumSize
                return orientation == .h ? minimumSize.width : minimumSize.height
            case .tilingContainer(let container):
                var sum: CGFloat = 0
                var max: CGFloat = 0
                for child in container.inhabitedChildren {
                    let length = child.minimumLength(orientation)
                    sum += length
                    max = Swift.max(max, length)
                }
                return container.layout == .tiles && container.orientation == orientation ? sum : max
        }
    }
}

/// Lengths of the children of a tiles container along its orientation.
///
/// Without minimums, it's the same as the classic AeroSpace layout: every child gets its weight plus an equal share of
/// the free (or missing) space. Children that would get less than their minimum get exactly their minimum, and the
/// rest of the space is redistributed among the other children the same way.
///
/// - Returns: nil if the minimums don't fit into `total`
func fitLengths(weights: [CGFloat], minimums: [CGFloat], total: CGFloat) -> [CGFloat]? {
    let count = weights.count
    guard count > 0 else { return [] }
    let delta = (total - weights.reduce(0, +)) / CGFloat(count)
    var lengths = weights.map { $0 + delta }
    guard minimums.contains(where: { $0 > 0 }) else { return lengths }
    if minimums.reduce(0, +) > total + 0.5 { return nil }

    var isFixed = [Bool](repeating: false, count: count)
    while true {
        var hasViolations = false
        for index in 0 ..< count where !isFixed[index] && minimums[index] > 0 && lengths[index] < minimums[index] {
            isFixed[index] = true
            lengths[index] = minimums[index]
            hasViolations = true
        }
        if !hasViolations { return lengths }

        var fixedLength: CGFloat = 0
        var freeWeight: CGFloat = 0
        var freeCount = 0
        for index in 0 ..< count {
            if isFixed[index] {
                fixedLength += lengths[index]
            } else {
                freeWeight += weights[index]
                freeCount += 1
            }
        }
        if freeCount == 0 { // All children are at their minimums. Share the rest equally
            let rest = (total - fixedLength) / CGFloat(count)
            return lengths.map { $0 + rest }
        }
        let freeDelta = (total - fixedLength - freeWeight) / CGFloat(freeCount)
        for index in 0 ..< count where !isFixed[index] {
            lengths[index] = weights[index] + freeDelta
        }
    }
}
