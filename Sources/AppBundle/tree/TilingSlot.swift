import AppKit
import Common

/// The place of a tiling window that left the tiling tree for a macOS native state (fullscreen, minimized, hidden app).
///
/// When the window leaves the native state, it comes back to the same place. Otherwise it would be placed as a new window
/// (e.g. with dwindle placement, it would split the most recent window), and every fullscreen round trip would change the
/// layout
struct TilingSlot {
    fileprivate weak var parent: TilingContainer?
    fileprivate let index: Int
    fileprivate let adaptiveWeight: CGFloat
    /// The sibling next to the window. The normalization flattens the parent when only the neighbor is left in it, the
    /// window splits the neighbor again then
    fileprivate weak var neighbor: TreeNode?
    fileprivate let isAfterNeighbor: Bool
    fileprivate let orientation: Orientation
    fileprivate let layout: Layout
    /// The window left the root with a single container. The normalization flattens the container into the root: the
    /// root takes its children, orientation and layout
    fileprivate let isRootFlattened: Bool
    fileprivate let neighborAdaptiveWeight: CGFloat
}

extension Window {
    /// Binds the window to the container of a macOS native state, see ``exitMacOsNativeUnconventionalState``
    @MainActor
    func enterMacosNativeState(_ container: NonLeafTreeNodeObject, prevParentKind: WindowParentCases.Kind, adaptiveWeight: CGFloat) {
        layoutReason = .macos(prevParentKind: prevParentKind)
        let parent = parent as? TilingContainer
        let index = ownIndex(in: .all)
        let previous = bind(to: container, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
        guard let parent, let index, let previous else {
            tilingSlot = nil
            return
        }
        let isAfterNeighbor = index > 0
        let neighbor = parent.children.getOrNil(atIndex: isAfterNeighbor ? index - 1 : 0) // The window is unbound already
        tilingSlot = TilingSlot(
            parent: parent,
            index: index,
            adaptiveWeight: previous.adaptiveWeight,
            neighbor: neighbor,
            isAfterNeighbor: isAfterNeighbor,
            orientation: parent.orientation,
            layout: parent.layout,
            isRootFlattened: parent.isRootContainer && parent.children.count == 1 && neighbor is TilingContainer,
            neighborAdaptiveWeight: neighbor?.getWeight(parent.orientation) ?? WEIGHT_AUTO,
        )
    }

    /// Binds the window back to its place in the tiling tree of the workspace. false if the place is gone
    @MainActor
    func bindBackToTilingSlot(on workspace: Workspace) -> Bool {
        guard let slot = tilingSlot else { return false }
        tilingSlot = nil
        let neighbor = slot.neighbor?.nodeWorkspace === workspace ? slot.neighbor : nil
        if let parent = slot.parent, parent.lifeStatus == .alive, parent.nodeWorkspace === workspace {
            if slot.isRootFlattened, slot.neighbor?.parent == nil, parent.orientation != slot.orientation, !parent.children.isEmpty {
                // Wrap the children that the root took from the flattened container again
                let children = parent.children
                let container = TilingContainer(parent: parent, adaptiveWeight: slot.neighborAdaptiveWeight, parent.orientation, parent.layout, index: 0)
                for child in children {
                    let binding = child.unbindFromParent()
                    child.bind(to: container, adaptiveWeight: binding.adaptiveWeight, index: INDEX_BIND_LAST)
                }
                parent.changeOrientation(slot.orientation)
                parent.layout = slot.layout
            }
            let index = if let neighbor, neighbor.parent === parent, let neighborIndex = neighbor.ownIndex(in: .all) {
                neighborIndex + (slot.isAfterNeighbor ? 1 : 0)
            } else {
                min(slot.index, parent.children.count)
            }
            bind(to: parent, adaptiveWeight: slot.adaptiveWeight, index: index)
            return true
        }
        // The normalization flattened the parent. Split the neighbor again
        guard let neighbor,
              let neighborParent = neighbor.parent as? TilingContainer,
              neighborParent.lifeStatus == .alive,
              let neighborIndex = neighbor.ownIndex(in: .all)
        else { return false }
        if neighborParent.orientation == slot.orientation {
            bind(to: neighborParent, adaptiveWeight: WEIGHT_AUTO, index: neighborIndex + (slot.isAfterNeighbor ? 1 : 0))
        } else {
            let neighborBinding = neighbor.unbindFromParent()
            let container = TilingContainer(
                parent: neighborParent,
                adaptiveWeight: neighborBinding.adaptiveWeight,
                slot.orientation,
                slot.layout,
                index: neighborBinding.index,
            )
            neighbor.bind(to: container, adaptiveWeight: WEIGHT_AUTO, index: 0)
            bind(to: container, adaptiveWeight: WEIGHT_AUTO, index: slot.isAfterNeighbor ? INDEX_BIND_LAST : 0)
        }
        return true
    }
}
