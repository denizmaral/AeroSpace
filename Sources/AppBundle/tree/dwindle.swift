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
    /// Gaps and accordion paddings are ignored
    @MainActor
    func estimatedTilingRect(excluding excluded: TreeNode? = nil) -> Rect? {
        guard let parent else { return nil }
        if let root = self as? TilingContainer, root.isRootContainer, let workspace = parent as? Workspace {
            return workspace.workspaceMonitorInfo.visibleRectPaddedByOuterGaps
        }
        guard let parent = parent as? TilingContainer, let parentRect = parent.estimatedTilingRect(excluding: excluded) else { return nil }
        switch parent.renderedLayout {
            case .accordion:
                return parentRect
            case .tiles:
                let siblings = parent.inhabitedChildren.filter { $0 != excluded }
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
struct DwindleSplit {
    fileprivate let anchor: TreeNode
    fileprivate let windowBindingGeneration: UInt64
}

extension Window {
    /// Captures the split for the window that was just bound right after its anchor. nil if the split doesn't apply
    @MainActor
    func captureDwindleSplit() -> DwindleSplit? {
        guard config.newWindowPlacement.splitsAnchorWindow,
              let parent = parent as? TilingContainer,
              let index = ownIndex(in: .all),
              index > 0
        else { return nil }
        return DwindleSplit(anchor: parent.children[index - 1], windowBindingGeneration: bindingGeneration)
    }

    /// Splits the anchor to make room for the window. It's a noop if the window was bound again since the split was
    /// captured, if the window is invisible (e.g. it's on another macOS Space), or if the anchor was moved
    @MainActor
    func applyDwindleSplit(_ split: DwindleSplit?) {
        guard let split,
              bindingGeneration == split.windowBindingGeneration,
              lifeStatus.isInhabited,
              config.newWindowPlacement.splitsAnchorWindow,
              let parent = parent as? TilingContainer,
              case let anchor = split.anchor,
              anchor.parent === parent,
              parent.lifeStatus == .alive,
              parent.layout == .tiles,
              anchor.tilingTreeNodeCasesOrDie().isInhabited,
              let index = ownIndex(in: .all),
              let anchorIndex = anchor.ownIndex(in: .all),
              anchorIndex + 1 == index
        else { return }

        // The anchor's rect before the window was put next to it
        let anchorRect = anchor.estimatedTilingRect(excluding: self)
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
        let isOnlyAnchorAndSelf = parent.inhabitedChildren.count { $0 != self } == 1
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
