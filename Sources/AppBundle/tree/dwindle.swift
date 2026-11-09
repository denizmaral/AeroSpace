import AppKit
import Common

// Hyprland-like "dwindle" placement of new tiling windows (`new-window-placement = 'dwindle'`)
//
// New tiling windows are always bound right after the most recent window (the "anchor"). In dwindle mode, the new
// window then takes half of the anchor's space instead of an equal share of the whole container. The split orientation
// is chosen by the aspect ratio of the anchor: wide anchors are split side by side, tall anchors are split top/bottom.
// When the window is closed, the normalization flattens the split container and the anchor gets its space back.

extension Window {
    /// The node that the window is going to split, or nil if dwindle placement doesn't apply.
    /// Capture it right after the window is bound, then pass it to ``dwindleSplit(_:)``
    @MainActor
    var dwindleAnchor: TreeNode? {
        guard config.newWindowPlacement == .dwindle,
              let parent = parent as? TilingContainer,
              let index = ownIndex(in: .all),
              index > 0
        else { return nil }
        return parent.children[index - 1]
    }

    /// Splits `anchor` to make room for the window.
    /// It's a noop if the tree has changed since `anchor` was captured (e.g., on-window-detected callback moved the window)
    @MainActor
    func dwindleSplit(_ anchor: TreeNode?) {
        guard let anchor,
              config.newWindowPlacement == .dwindle,
              let parent = parent as? TilingContainer,
              anchor.parent === parent,
              parent.lifeStatus == .alive,
              parent.layout == .tiles,
              anchor.tilingTreeNodeCasesOrDie().isInhabited,
              let index = ownIndex(in: .all),
              let anchorIndex = anchor.ownIndex(in: .all),
              anchorIndex + 1 == index
        else { return }

        let anchorOrientation: Orientation? = anchor.lastAppliedLayoutPhysicalRect.map { $0.width >= $0.height ? .h : .v }
        let isOnlyAnchorAndSelf = parent.inhabitedChildren.count { $0 != self } == 1
        if isOnlyAnchorAndSelf {
            // The window and the anchor split the whole container equally. Only the orientation needs to be decided
            if parent.isRootContainer, let anchorOrientation {
                parent.changeOrientation(anchorOrientation)
            }
            return
        }
        // Alternate orientations (spiral) if the anchor wasn't laid out yet
        let targetOrientation = anchorOrientation ?? parent.orientation.opposite
        if targetOrientation == parent.orientation {
            // Nested containers with the same orientation are not allowed by normalization. Split the weight instead
            let halfWeight = anchor.getWeight(parent.orientation) / 2
            anchor.setWeight(parent.orientation, halfWeight)
            setWeight(parent.orientation, halfWeight)
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
}
