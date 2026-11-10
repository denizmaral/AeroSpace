import AppKit
import Common

/// The place of a tiling window that left the tiling tree for a macOS native state (fullscreen, minimized, hidden app).
///
/// When the window leaves the native state, it comes back to the same place. Otherwise it would be placed as a new window
/// (e.g. with dwindle placement, it would split the most recent window), and every fullscreen round trip would change the
/// layout. Several windows of a container may leave at the same time (e.g. the app is hidden), they come back in their
/// order whichever comes back first
struct TilingSlot {
    fileprivate weak var parent: TilingContainer?
    fileprivate var adaptiveWeight: CGFloat
    /// The siblings on the left of the window, including the windows of the container that are away in a macOS native
    /// state themselves. The window comes back right after the last of them that is in the container
    fileprivate let leftSiblings: [WeakTreeNode]
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
    /// The window was the last child of its parent: the normalization removes the empty container. The first of its
    /// windows that comes back binds it back
    fileprivate var emptiedContainer: EmptiedContainer?
}

private struct EmptiedContainer {
    /// Strong: the windows of the container that are away refer to it
    let container: TilingContainer
    weak var parent: TilingContainer?
    let leftSiblings: [WeakTreeNode]
    let adaptiveWeight: CGFloat
}

private struct WeakTreeNode {
    weak var node: TreeNode?
}

extension Window {
    /// Binds the window to the container of a macOS native state, see ``exitMacOsNativeUnconventionalState``
    @MainActor
    func enterMacosNativeState(_ container: NonLeafTreeNodeObject, prevParentKind: WindowParentCases.Kind, adaptiveWeight: CGFloat) {
        layoutReason = .macos(prevParentKind: prevParentKind)
        bindToMacosNativeStateContainer(container, adaptiveWeight: adaptiveWeight)
    }

    /// Binds the window to the container of a macOS native state. A tiling window remembers its place (``tilingSlot``)
    @MainActor
    func bindToMacosNativeStateContainer(_ container: NonLeafTreeNodeObject, adaptiveWeight: CGFloat) {
        switch windowParentCases {
            case .tilingContainer(let parent):
                let siblings = childrenIncludingAwayWindows(parent)
                let previous = bind(to: container, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST).orDie()
                tilingSlot = TilingSlot(leaving: self, parent, previous, siblings)
            case .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer, .macosMinimizedWindowsContainer:
                // From one macOS native state to another (e.g. the macos-native-fullscreen command binds the window to
                // the fullscreen container before the native state is detected). The window keeps its place
                bind(to: container, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
            case .floatingWindowsContainer, .macosPopupWindowsContainer, nil:
                tilingSlot = nil
                bind(to: container, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
        }
    }

    /// Binds the window back to its place in the tiling tree of the workspace. false if the place is gone
    @MainActor
    func bindBackToTilingSlot(on workspace: Workspace) -> Bool {
        guard let slot = tilingSlot else { return false }
        tilingSlot = nil
        if let parent = slot.parent, parent.parent == nil {
            bindBackEmptiedContainer(parent, on: workspace, ownRecord: slot.emptiedContainer)
        }
        return bindToParent(of: slot, on: workspace) || bindNextToNeighbor(of: slot, on: workspace)
    }

    /// The window is away in a macOS native state, and the window that split it in dwindle placement is closed. The
    /// weight goes back to the window when it comes back. See ``returnWeightToDwindleSplitAnchor()``
    @MainActor
    func addWeightToTilingSlot(_ weight: CGFloat, of parent: TilingContainer) {
        guard let slot = tilingSlot, slot.parent === parent, slot.orientation == parent.orientation else { return }
        tilingSlot?.adaptiveWeight += weight
    }

    @MainActor
    private func bindToParent(of slot: TilingSlot, on workspace: Workspace) -> Bool {
        guard let parent = slot.parent, parent.lifeStatus == .alive, parent.nodeWorkspace === workspace else { return false }
        if slot.isRootFlattened, slot.neighbor?.parent == nil, !parent.children.isEmpty,
           parent.orientation != slot.orientation || parent.layout != slot.layout
        {
            // Wrap the children that the root took from the flattened container again
            let children = parent.children
            let container = TilingContainer(parent: parent, adaptiveWeight: slot.neighborAdaptiveWeight, parent.orientation, parent.layout, index: 0)
            for child in children {
                let binding = child.unbindFromParent()
                child.bind(to: container, adaptiveWeight: binding.adaptiveWeight, index: INDEX_BIND_LAST)
            }
            // The other windows of the flattened container that are away come back to it
            for window in awayWindows(of: parent) {
                window.tilingSlot?.parent = container
            }
            parent.changeOrientation(slot.orientation)
            parent.layout = slot.layout
            bind(to: parent, adaptiveWeight: slot.adaptiveWeight, index: slot.isAfterNeighbor ? INDEX_BIND_LAST : 0)
        } else {
            bind(to: parent, adaptiveWeight: slot.adaptiveWeight, index: insertionIndex(in: parent.children, after: slot.leftSiblings))
        }
        return true
    }

    /// The normalization flattened the parent: the window splits its neighbor again
    @MainActor
    private func bindNextToNeighbor(of slot: TilingSlot, on workspace: Workspace) -> Bool {
        func isTiling(_ node: TreeNode) -> Bool {
            node.nodeWorkspace === workspace && (node.parent as? TilingContainer)?.lifeStatus == .alive
        }
        let neighbor: TreeNode
        let isAfterNeighbor: Bool
        if let node = slot.neighbor, isTiling(node) {
            (neighbor, isAfterNeighbor) = (node, slot.isAfterNeighbor)
        } else if let away = slot.neighbor as? Window, away.nodeWorkspace === workspace, let awaySlot = away.tilingSlot,
                  bindToParent(of: awaySlot, on: workspace)
        {
            // The neighbor is away too. The window takes its place, and the neighbor comes back next to the window
            away.tilingSlot = TilingSlot(
                parent: nil,
                adaptiveWeight: WEIGHT_AUTO,
                leftSiblings: [],
                neighbor: self,
                isAfterNeighbor: !slot.isAfterNeighbor,
                orientation: slot.orientation,
                layout: slot.layout,
                isRootFlattened: false,
                neighborAdaptiveWeight: WEIGHT_AUTO,
                emptiedContainer: awaySlot.emptiedContainer,
            )
            return true
        } else if let node = slot.leftSiblings.reversed().lazy.compactMap(\.node).first(where: isTiling) {
            // E.g. the window was the last child of its container
            (neighbor, isAfterNeighbor) = (node, true)
        } else {
            return false
        }
        let neighborParent = (neighbor.parent as? TilingContainer).orDie()
        let neighborIndex = neighbor.ownIndex(in: .all).orDie()
        if neighborParent.orientation == slot.orientation {
            bind(to: neighborParent, adaptiveWeight: WEIGHT_AUTO, index: neighborIndex + (isAfterNeighbor ? 1 : 0))
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
            bind(to: container, adaptiveWeight: WEIGHT_AUTO, index: isAfterNeighbor ? INDEX_BIND_LAST : 0)
        }
        return true
    }
}

extension TilingSlot {
    @MainActor
    fileprivate init(leaving window: Window, _ parent: TilingContainer, _ previous: BindingData, _ siblings: [TreeNode]) {
        let isAfterNeighbor = previous.index > 0
        let neighbor = parent.children.getOrNil(atIndex: isAfterNeighbor ? previous.index - 1 : 0) // The window is unbound already
        let virtualIndex = siblings.firstIndex { $0 === window } ?? siblings.count
        var emptiedContainer: EmptiedContainer? = nil
        if parent.children.isEmpty, !parent.isRootContainer, let grandparent = parent.parent as? TilingContainer {
            let parentSiblings = childrenIncludingAwayWindows(grandparent)
            let parentIndex = parentSiblings.firstIndex { $0 === parent } ?? parentSiblings.count
            emptiedContainer = EmptiedContainer(
                container: parent,
                parent: grandparent,
                leftSiblings: parentSiblings[..<parentIndex].map { WeakTreeNode(node: $0) },
                adaptiveWeight: parent.getWeight(grandparent.orientation),
            )
        }
        self.init(
            parent: parent,
            adaptiveWeight: previous.adaptiveWeight,
            leftSiblings: siblings[..<virtualIndex].map { WeakTreeNode(node: $0) },
            neighbor: neighbor,
            isAfterNeighbor: isAfterNeighbor,
            orientation: parent.orientation,
            layout: parent.layout,
            isRootFlattened: parent.isRootContainer && parent.children.count == 1 && neighbor is TilingContainer,
            neighborAdaptiveWeight: neighbor?.getWeight(parent.orientation) ?? WEIGHT_AUTO,
            emptiedContainer: emptiedContainer,
        )
    }
}

/// The container was removed by the normalization when its last window left. The first of its windows that comes back
/// binds it back to its place
@MainActor
private func bindBackEmptiedContainer(_ container: TilingContainer, on workspace: Workspace, ownRecord: EmptiedContainer?) {
    let away = allAwayWindows(of: workspace)
    let record = ownRecord?.container === container
        ? ownRecord
        : away.lazy.compactMap { $0.tilingSlot?.emptiedContainer }.first { $0.container === container }
    guard let record, let parent = record.parent, parent.lifeStatus == .alive, parent.nodeWorkspace === workspace else { return }
    container.lifeStatus = .alive
    container.bind(to: parent, adaptiveWeight: record.adaptiveWeight, index: insertionIndex(in: parent.children, after: record.leftSiblings))
    for window in away where window.tilingSlot?.emptiedContainer?.container === container {
        window.tilingSlot?.emptiedContainer = nil // The tree holds the container now
    }
}

/// The windows of the workspace that are away in a macOS native state and have a place in its tiling tree
@MainActor
private func allAwayWindows(of workspace: Workspace) -> [Window] {
    let containers: [NonLeafTreeNodeObject] = [
        workspace.macOsNativeFullscreenWindowsContainer,
        workspace.macOsNativeHiddenAppsWindowsContainer,
        macosMinimizedWindowsContainer,
    ]
    return containers.flatMap(\.children).compactMap { $0 as? Window }.filter { $0.tilingSlot != nil }
}

/// The windows that are away in a macOS native state, and come back to `parent`
@MainActor
private func awayWindows(of parent: TilingContainer) -> [Window] {
    guard let workspace = parent.nodeWorkspace else { return [] }
    return allAwayWindows(of: workspace).filter { $0.tilingSlot?.parent === parent }
}

/// The children of the container with the windows that are away (see ``awayWindows(of:)``) at their places
@MainActor
private func childrenIncludingAwayWindows(_ parent: TilingContainer) -> [TreeNode] {
    var result = parent.children
    for window in awayWindows(of: parent) {
        result.insert(window, at: insertionIndex(in: result, after: window.tilingSlot.orDie().leftSiblings))
    }
    return result
}

/// Right after the last of `leftSiblings` that is in `nodes`. 0 if none of them is
private func insertionIndex(in nodes: [TreeNode], after leftSiblings: [WeakTreeNode]) -> Int {
    for sibling in leftSiblings.reversed() {
        if let node = sibling.node, let index = nodes.firstIndex(where: { $0 === node }) {
            return index + 1
        }
    }
    return 0
}
