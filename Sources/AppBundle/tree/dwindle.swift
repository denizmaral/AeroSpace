import AppKit
import Common

// Hyprland-like placement of new tiling windows (`new-window-placement = 'dwindle' | 'balanced'`)
//
// New tiling windows are always bound right after the "anchor" window: the most recent tiling window ('dwindle') or the
// largest tiling window ('balanced'). Then the new window takes half of the anchor's space instead of an equal share of
// the whole container. The split orientation is chosen by the aspect ratio of the anchor: wide anchors are split side
// by side, tall anchors are split top/bottom. When the window is closed, the normalization flattens the split container
// and the anchor gets its space back.

extension NewWindowPlacement {
    /// Whether new tiling windows split the anchor window in half instead of taking an equal share of the container
    var splitsAnchorWindow: Bool { self != .i3 }
}

extension Workspace {
    /// The window that a new tiling window is put next to
    @MainActor
    var newTilingWindowAnchor: Window? {
        switch config.newWindowPlacement {
            case .i3: mostRecentWindowRecursive
            // Split the most recent tiling window, even if a floating window was focused after it
            case .dwindle: rootTilingContainer.mostRecentWindowRecursive
            case .balanced: largestTilingWindow ?? rootTilingContainer.mostRecentWindowRecursive
        }
    }

    /// The tiling window with the biggest area. The most recent window wins among windows of (almost) the same size
    @MainActor
    private var largestTilingWindow: Window? {
        let mostRecent = rootTilingContainer.mostRecentWindowRecursive
        var result: (window: Window, area: CGFloat)? = nil
        for window in rootTilingContainer.allLeafWindowsRecursive {
            guard let rect = window.estimatedTilingRect() else { continue }
            let area = rect.width * rect.height
            if let current = result {
                let isSameSize = abs(area - current.area) <= current.area * 0.01
                if isSameSize ? window == mostRecent : area > current.area {
                    result = (window, area)
                }
            } else {
                result = (window, area)
            }
        }
        return result?.window
    }
}

extension TreeNode {
    /// The rect that the tiling node would get if the workspace was laid out right now.
    /// Unlike `lastAppliedLayoutPhysicalRect`, it's up to date right after the tree is changed.
    /// Gaps and accordion paddings are ignored. `ignored` nodes are treated as if they weren't in the tree
    @MainActor
    func estimatedTilingRect(ignoring ignored: [TreeNode] = []) -> Rect? {
        guard let parent else { return nil }
        if let root = self as? TilingContainer, root.isRootContainer, let workspace = parent as? Workspace {
            return workspace.workspaceMonitorInfo.visibleRectPaddedByOuterGaps
        }
        guard let parent = parent as? TilingContainer, let parentRect = parent.estimatedTilingRect(ignoring: ignored) else { return nil }
        switch parent.renderedLayout {
            case .accordion:
                return parentRect
            case .tiles:
                let siblings = parent.inhabitedChildren.filter { child in !ignored.contains { $0 === child } }
                guard let index = siblings.firstIndex(of: self) else { return nil }
                let orientation = parent.orientation
                let weights = siblings.map { $0.getWeight(orientation) }
                // The same math as in layoutTiles
                let delta = (parentRect.getDimension(orientation) - weights.reduce(0, +)) / CGFloat(siblings.count)
                let offset = weights[..<index].reduce(0, +) + delta * CGFloat(index)
                let length = weights[index] + delta
                return switch orientation {
                    case .h: Rect(topLeftX: parentRect.topLeftX + offset, topLeftY: parentRect.topLeftY, width: length, height: parentRect.height)
                    case .v: Rect(topLeftX: parentRect.topLeftX, topLeftY: parentRect.topLeftY + offset, width: parentRect.width, height: length)
                }
        }
    }
}

/// The split of the anchor node that makes room for a newly bound tiling window.
///
/// It's captured right after the window is bound next to the anchor, and applied later (e.g. after on-window-detected
/// callbacks that may move the window to another workspace). If the window is bound again in the meantime (moved,
/// floated, re-tiled), the captured split is stale and it's not applied.
///
/// Several windows may be detected at the same time: the callbacks of one window suspend, and another session detects
/// the next window meanwhile. The splits are applied in the order of capturing, and every split ignores the windows
/// that were detected after it. The result is the same as if the windows were detected one after another
@MainActor
final class DwindleSplit {
    fileprivate let window: Window
    fileprivate let anchor: TreeNode
    private let windowBindingGeneration: UInt64
    fileprivate var state: State = .captured

    fileprivate enum State {
        /// The owner applies or discards it later
        case captured
        /// Applied as soon as the splits that were captured before it are applied
        case ready
        case done
    }

    fileprivate init(window: Window, anchor: TreeNode) {
        self.window = window
        self.anchor = anchor
        self.windowBindingGeneration = window.bindingGeneration
    }

    /// The window was bound again since the split was captured
    fileprivate var isStale: Bool { window.bindingGeneration != windowBindingGeneration }

    /// The split won't be applied (e.g. the session is canceled). Later splits don't wait for it. No-op once applied
    func discard() {
        guard state == .captured else { return }
        state = .done
        applyReadyDwindleSplits()
    }
}

/// The splits that aren't applied yet, in the order of capturing. See ``DwindleSplit``
@MainActor var dwindleSplitQueue: [DwindleSplit] = []

@MainActor
private func applyReadyDwindleSplits() {
    while let split = dwindleSplitQueue.first {
        switch split.state {
            case .captured where !split.isStale: return // Wait for the owner. A stale split is never applied
            case .captured, .done:
                split.state = .done
                dwindleSplitQueue.removeFirst()
            case .ready:
                split.state = .done
                dwindleSplitQueue.removeFirst()
                if split.isStale { continue }
                // The windows that were detected after this one don't exist yet from the point of view of the split
                let later = dwindleSplitQueue.filter { $0.state != .done && !$0.isStale }.map(\.window)
                split.window.split(split.anchor, ignoring: later)
        }
    }
}

extension Window {
    /// Captures the split for the window that was just bound right after its anchor. nil if the split doesn't apply.
    /// The caller must apply (``applyDwindleSplit(_:)``) or discard it, later splits wait for it
    @MainActor
    func captureDwindleSplit() -> DwindleSplit? {
        guard config.newWindowPlacement.splitsAnchorWindow,
              let parent = parent as? TilingContainer,
              let index = ownIndex(in: .all),
              index > 0
        else { return nil }
        let split = DwindleSplit(window: self, anchor: parent.children[index - 1])
        dwindleSplitQueue.append(split)
        return split
    }

    /// Splits the anchor to make room for the window, once the splits that were captured before are applied. It's a
    /// noop if the window was bound again since the split was captured, if the window is invisible (e.g. it's on another
    /// macOS Space), or if the anchor is gone
    @MainActor
    func applyDwindleSplit(_ split: DwindleSplit?) {
        guard let split, split.state == .captured else { return }
        check(split.window === self)
        split.state = .ready
        applyReadyDwindleSplits()
    }

    @MainActor
    fileprivate func split(_ anchor: TreeNode, ignoring later: [Window]) {
        guard lifeStatus.isInhabited,
              config.newWindowPlacement.splitsAnchorWindow,
              parent is TilingContainer,
              let parent = anchor.parent as? TilingContainer,
              parent.lifeStatus == .alive,
              parent.layout == .tiles,
              anchor.tilingTreeNodeCasesOrDie().isInhabited,
              anchor.nodeWorkspace === nodeWorkspace
        else { return }
        // An earlier split may have moved the anchor (e.g. into a new container). Follow it, the same as a window that
        // is detected after the earlier one
        if self.parent !== parent || ownIndex(in: .all) != anchor.ownIndex(in: .all).map({ $0 + 1 }) {
            unbindFromParent()
            bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: anchor.ownIndex(in: .all).orDie() + 1)
        }
        let ignored: [TreeNode] = [self] + later

        // The anchor's rect before the window was put next to it
        let anchorRect = anchor.estimatedTilingRect(ignoring: ignored)
        // Split in the other direction if the known minimum sizes (see minimumSize.swift) only fit that way
        func fits(_ orientation: Orientation, _ rect: Rect) -> Bool {
            let half = rect.getDimension(orientation) / 2
            return anchor.minimumLength(orientation) <= half && minimumLength(orientation) <= half
        }
        let anchorOrientation: Orientation?
        if let anchorRect {
            let preferred: Orientation = anchorRect.width >= anchorRect.height ? .h : .v
            anchorOrientation = !fits(preferred, anchorRect) && fits(preferred.opposite, anchorRect) ? preferred.opposite : preferred
        } else {
            anchorOrientation = nil
        }
        let isOnlyAnchorAndSelf = parent.inhabitedChildren.count { child in !ignored.contains { $0 === child } } == 1
        if isOnlyAnchorAndSelf {
            // The window and the anchor split the whole container equally. Only the orientation needs to be decided
            if parent.isRootContainer, let anchorOrientation {
                parent.changeOrientation(anchorOrientation)
            }
            return
        }
        let targetOrientation = anchorOrientation ?? parent.orientation.opposite
        if targetOrientation == parent.orientation {
            // Nested containers with the same orientation are not allowed by normalization. Split the weight instead,
            // and give it back to the anchor when the window is closed (the nested container case is collapsed by
            // the normalization instead)
            let halfWeight = anchor.getWeight(parent.orientation) / 2
            anchor.setWeight(parent.orientation, halfWeight)
            setWeight(parent.orientation, halfWeight)
            dwindleSplitAnchor = anchor
        } else {
            let anchorBinding = anchor.unbindFromParent()
            unbindFromParent()
            let container = TilingContainer(
                parent: parent,
                adaptiveWeight: anchorBinding.adaptiveWeight,
                targetOrientation,
                .tiles,
                index: anchorBinding.index,
            )
            anchor.bind(to: container, adaptiveWeight: WEIGHT_AUTO, index: 0)
            bind(to: container, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
    }

    /// See `dwindleSplitAnchor`
    @MainActor
    func returnWeightToDwindleSplitAnchor() {
        defer { dwindleSplitAnchor = nil }
        guard let anchor = dwindleSplitAnchor,
              let parent = parent as? TilingContainer,
              anchor.parent === parent,
              parent.layout == .tiles
        else { return }
        let orientation = parent.orientation
        anchor.setWeight(orientation, anchor.getWeight(orientation) + getWeight(orientation))
    }
}
