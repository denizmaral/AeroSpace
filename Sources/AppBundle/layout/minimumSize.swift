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

enum MinimumSizeObservation: Equatable {
    /// The window has the size that the layout asked for
    case fits
    /// The window is bigger. It must be confirmed by the next observation
    case pending
    /// The window refused the size twice. `Window.learnedMinimumSize` is updated
    case learned
}

extension Window {
    /// Distinguishes rounding (e.g. Terminal snaps its size to the character grid) from refusing the size
    private static let minimumSizeTolerance: CGFloat = 8
    private static let minimumSizeConfirmationDelay: Duration = .milliseconds(400)

    /// Call it after kAXResizedNotification that isn't caused by the mouse
    @MainActor
    func scheduleMinimumSizeCheck() {
        minimumSizeCheckTask?.cancel()
        minimumSizeCheckTask = Task.startUnstructured { @MainActor [weak self] in
            guard let self else { return }
            var observation = await observeSize()
            if observation == .pending {
                // The first observation may be an animation, a late frame of an asynchronous app (e.g. Electron),
                // or a resize initiated by the app itself. Meanwhile, the layout sends the frame again
                try await Task.sleep(for: Self.minimumSizeConfirmationDelay)
                observation = await observeSize()
            }
            if observation == .learned {
                scheduleCancellableCompleteRefreshSession(.minimumSizeLearned)
            }
        }
    }

    /// Compares the actual size of the tiling window with the size that the layout asked for
    @MainActor
    func observeSize() async -> MinimumSizeObservation {
        guard case .tilingContainer = windowParentCases,
              !isFullscreen,
              let requested = lastAppliedLayoutPhysicalRect,
              let actual = try? await getAxSize(.cancellable)
        else {
            pendingMinimumSize = nil
            return .fits
        }
        let refused = CGSize(
            width: actual.width > requested.width + Self.minimumSizeTolerance ? actual.width : 0,
            height: actual.height > requested.height + Self.minimumSizeTolerance ? actual.height : 0,
        )
        if refused == .zero {
            pendingMinimumSize = nil
            return .fits
        }
        guard let pending = pendingMinimumSize,
              abs(pending.width - refused.width) <= 2,
              abs(pending.height - refused.height) <= 2
        else {
            pendingMinimumSize = refused
            return .pending
        }
        pendingMinimumSize = nil
        learnedMinimumSize = CGSize(
            width: max(learnedMinimumSize.width, refused.width),
            height: max(learnedMinimumSize.height, refused.height),
        )
        return .learned
    }
}

extension TreeNode {
    /// The minimum length of the tiling node along the orientation. 0 if unknown
    @MainActor
    func minimumLength(_ orientation: Orientation) -> CGFloat {
        switch tilingTreeNodeCasesOrDie() {
            case .window(let window):
                return orientation == .h ? window.learnedMinimumSize.width : window.learnedMinimumSize.height
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
