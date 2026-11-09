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

extension Window {
    /// Distinguishes rounding (e.g. Terminal snaps its size to the character grid) from refusing the size
    private static let minimumSizeTolerance: CGFloat = 8
    private static let minimumSizeConfirmationDelay: Duration = .milliseconds(400)

    /// Call it after kAXResizedNotification that isn't caused by the mouse. See ``checkMinimumSize(confirmationDelay:)``
    @MainActor
    func scheduleMinimumSizeCheck() {
        if minimumSizeCheckTask != nil { return } // Bursts of notifications must not shortcut the running check
        minimumSizeCheckTask = Task.startUnstructured { @MainActor [weak self] in
            defer { self?.minimumSizeCheckTask = nil }
            if try await self?.checkMinimumSize(confirmationDelay: Self.minimumSizeConfirmationDelay) == true {
                scheduleCancellableCompleteRefreshSession(.minimumSizeLearned)
            }
        }
    }

    /// A self-contained two-step check. The window must be bigger than the layout asked for, then the requested frame
    /// is sent again, and after the delay the window must still be bigger by the same size. A single observation may
    /// be an animation, a late frame of an asynchronous app (e.g. Electron) or a resize initiated by the app itself.
    ///
    /// - Returns: true if a new minimum size was learned
    @MainActor
    func checkMinimumSize(confirmationDelay: Duration) async throws -> Bool {
        guard let requested = minimumSizeCheckableRect, let actual = try? await getAxSize(.cancellable) else { return false }
        forgetMinimumSizeIfSmaller(actual)
        guard let first = refusedSize(actual, requested) else { return false }

        invalidateSentFrame()
        setAxFrame(requested.topLeftCorner, CGSize(width: requested.width, height: requested.height))
        try await Task.sleep(for: confirmationDelay)

        guard minimumSizeCheckableRect == requested, // Otherwise, the layout has changed and the observation is inconclusive
              let actual = try? await getAxSize(.cancellable),
              let second = refusedSize(actual, requested),
              abs(second.width - first.width) <= 2,
              abs(second.height - first.height) <= 2
        else { return false }
        let minimumSize = effectiveMinimumSize
        learnedMinimumSize = CGSize(width: max(minimumSize.width, second.width), height: max(minimumSize.height, second.height))
        learnedMinimumSizeWorkspace = nodeWorkspace?.name
        return true
    }

    /// The learned minimum size. It's forgotten when the window is moved to another workspace (the minimum size of a
    /// window may change, e.g. when its sidebar is hidden). If the window still doesn't fit, its minimum is learned again
    @MainActor
    var effectiveMinimumSize: CGSize {
        learnedMinimumSizeWorkspace == nil || learnedMinimumSizeWorkspace == nodeWorkspace?.name ? learnedMinimumSize : .zero
    }

    /// The rect that the layout asked for, if the window can be checked: a tiling window on a visible workspace.
    /// Windows of invisible workspaces are hidden in the corner, only their position is sent
    @MainActor
    private var minimumSizeCheckableRect: Rect? {
        guard case .tilingContainer = windowParentCases, !isFullscreen, nodeWorkspace?.isVisible == true else { return nil }
        return lastAppliedLayoutPhysicalRect
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
