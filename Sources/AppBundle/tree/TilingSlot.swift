import AppKit
import Common

/// The place of a tiling window that left the tiling tree for a macOS native state (fullscreen, minimized, hidden app).
///
/// When the window leaves the native state, it comes back to the same place. Otherwise it would be placed as a new window
/// (e.g. with dwindle placement, it would split the most recent window), and every fullscreen round trip would change the
/// layout. Several windows of a container may leave at the same time (e.g. the app is hidden), they come back in their
/// order whichever comes back first
struct TilingSlot {
    /// Strong: the windows that left the same container are recognized by it after the normalization flattened it
    /// (the parent references of the tree are weak, there is no cycle)
    fileprivate var parent: TilingContainer?
    fileprivate var adaptiveWeight: CGFloat
    /// The other children of the parent when the window left, including the nodes that are away themselves (see
    /// ``awayNodes(of:)``). The window comes back right after the last of the siblings on its left that is in the parent,
    /// with its old share of the parent (see ``restoredWeight(_:siblings:in:)``)
    fileprivate var siblings: [WeightedSibling]
    /// The number of the siblings on the left of the window
    fileprivate let index: Int
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

    fileprivate var leftSiblings: ArraySlice<WeightedSibling> { siblings[..<index] }
}

private struct EmptiedContainer {
    /// Strong: the windows of the container that are away refer to it
    let container: TilingContainer
    weak var parent: TilingContainer?
    /// See ``TilingSlot/siblings``
    let siblings: [WeightedSibling]
    let index: Int
    let adaptiveWeight: CGFloat

    var leftSiblings: ArraySlice<WeightedSibling> { siblings[..<index] }
}

/// A sibling and its weight when the window left. The weights are proportions (see
/// ``TilingContainer/proportionalLengths(_:total:)``): a weight means something only next to the weights of the same
/// container at the same time
private struct WeightedSibling {
    weak var node: TreeNode?
    let weight: CGFloat
    /// The sibling was away itself (see ``awayNodes(of:)``): it didn't take a share of the parent. Its weight is 0: the
    /// weight in its own slot may be from a time when the weights of the parent had another scale
    let isAway: Bool
    /// The windows of a container sibling. The normalization may replace the container meanwhile (flattened when one of
    /// its windows left, wrapped again when it came back): the child that holds them now takes its place
    var windows: [WeakWindow] = []
}

private struct WeakWindow {
    weak var window: Window?
}

/// A node that is away and comes back to its parent: a window in a macOS native state, or a container that the
/// normalization removed when its last window left
private struct AwayNode {
    let node: TreeNode
    let leftSiblings: ArraySlice<WeightedSibling>
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
                let siblings = siblingsIncludingAwayNodes(parent)
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

    /// The container of the window that is away in a macOS native state, and the weight that the window would get there
    /// if it came back now (the weight in its slot may have another scale than the weights in the container now)
    @MainActor
    var tilingSlotPlace: (TilingContainer, CGFloat)? {
        guard let slot = tilingSlot, let parent = slot.parent else { return nil }
        return (parent, restoredWeight(slot.adaptiveWeight, siblings: slot.siblings, in: parent))
    }

    /// The window is away in a macOS native state, and `closed`, the window that split it in dwindle placement, is
    /// closed. The window takes the share of `closed` when it comes back. See ``returnWeightToDwindleSplitAnchor()``
    @MainActor
    func takeShareInTilingSlot(of closed: Window, in parent: TilingContainer) {
        guard let slot = tilingSlot, slot.parent === parent,
              let index = slot.siblings.firstIndex(where: { $0.node === closed && !$0.isAway })
        else { return }
        // The weight of `closed` when the window left: the same scale as the weight of the window
        tilingSlot?.adaptiveWeight += slot.siblings[index].weight
        // Otherwise its share would be free for all children too
        tilingSlot?.siblings[index] = WeightedSibling(node: nil, weight: 0, isAway: false)
    }

    @MainActor
    private func bindToParent(of slot: TilingSlot, on workspace: Workspace) -> Bool {
        guard let parent = slot.parent, parent.lifeStatus == .alive, parent.nodeWorkspace === workspace else { return false }
        if slot.needsRootRewrap(parent) {
            // The root has only the wrapper and the window then: both get their old weights
            rewrapRoot(parent, as: slot)
            bind(to: parent, adaptiveWeight: slot.adaptiveWeight, index: slot.isAfterNeighbor ? INDEX_BIND_LAST : 0)
            return true
        }
        if parent.isRootContainer, let away = allAwayWindows(of: workspace).first(where: { $0.tilingSlot?.needsRootRewrap(parent) == true }),
           let awaySlot = away.tilingSlot
        {
            // The window left the root before the window that flattened it. The root has the orientation of the
            // flattened container now: wrap its children again on behalf of the window that is still away
            let wrapper = rewrapRoot(parent, as: awaySlot)
            away.tilingSlot?.neighbor = wrapper
        }
        bind(
            to: parent,
            adaptiveWeight: restoredWeight(slot.adaptiveWeight, siblings: slot.siblings, in: parent),
            index: insertionIndex(in: parent.children, after: slot.leftSiblings),
        )
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
        var neighborSlot = slot // The slot that knows the old weight of `neighbor`
        if let node = slot.neighbor, isTiling(node) {
            (neighbor, isAfterNeighbor) = (node, slot.isAfterNeighbor)
        } else if let away = slot.neighbor as? Window, away.nodeWorkspace === workspace, let awaySlot = away.tilingSlot,
                  bindToParent(of: awaySlot, on: workspace)
        {
            // The neighbor is away too. The window takes its place, and the neighbor comes back next to the window
            // (both get their old weights in the container then: the window is its sibling with its old weight)
            away.tilingSlot = TilingSlot(
                parent: nil,
                adaptiveWeight: slot.neighborAdaptiveWeight,
                siblings: [WeightedSibling(node: self, weight: slot.adaptiveWeight, isAway: false)],
                index: slot.isAfterNeighbor ? 0 : 1,
                neighbor: self,
                isAfterNeighbor: !slot.isAfterNeighbor,
                orientation: slot.orientation,
                layout: slot.layout,
                isRootFlattened: false,
                neighborAdaptiveWeight: slot.adaptiveWeight,
                emptiedContainer: awaySlot.emptiedContainer,
            )
            return true
        } else if let (node, awaySlot) = tilingNeighbor(ofAwayNeighborsOf: slot, isTiling) {
            // The neighbor left the same container and is still away (e.g. two of three windows left, the normalization
            // flattened the container): the window takes its place next to its neighbor
            (neighbor, isAfterNeighbor, neighborSlot) = (node, awaySlot.isAfterNeighbor, awaySlot)
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
            // The container takes the place of the flattened one: its windows that are still away come back to it (and
            // they are away from it for the share of the window below)
            if let flattened = slot.parent {
                for window in allAwayWindows(of: workspace) where window.tilingSlot?.parent === flattened {
                    window.tilingSlot?.parent = container
                }
            }
            // The neighbor gets its old weight if the slot knows it, the window its old share next to it
            let isKnownNeighbor = neighbor === neighborSlot.neighbor && neighborSlot.neighborAdaptiveWeight > 0
            neighbor.bind(to: container, adaptiveWeight: isKnownNeighbor ? neighborSlot.neighborAdaptiveWeight : WEIGHT_AUTO, index: 0)
            bind(
                to: container,
                adaptiveWeight: restoredWeight(slot.adaptiveWeight, siblings: slot.siblings, in: container),
                index: isAfterNeighbor ? INDEX_BIND_LAST : 0,
            )
        }
        return true
    }
}

extension TilingSlot {
    /// `siblings`: the children of `parent` with the window, before the window left
    @MainActor
    fileprivate init(leaving window: Window, _ parent: TilingContainer, _ previous: BindingData, _ siblings: [WeightedSibling]) {
        let isAfterNeighbor = previous.index > 0
        let neighbor = parent.children.getOrNil(atIndex: isAfterNeighbor ? previous.index - 1 : 0) // The window is unbound already
        let index = siblings.firstIndex { $0.node === window } ?? siblings.count
        var emptiedContainer: EmptiedContainer? = nil
        if parent.children.isEmpty, !parent.isRootContainer, let grandparent = parent.parent as? TilingContainer {
            var parentSiblings = siblingsIncludingAwayNodes(grandparent)
            let parentIndex = parentSiblings.firstIndex { $0.node === parent } ?? parentSiblings.count
            if parentIndex < parentSiblings.count { parentSiblings.remove(at: parentIndex) }
            emptiedContainer = EmptiedContainer(
                container: parent,
                parent: grandparent,
                siblings: parentSiblings,
                index: parentIndex,
                adaptiveWeight: parent.getWeight(grandparent.orientation),
            )
        }
        self.init(
            parent: parent,
            adaptiveWeight: previous.adaptiveWeight,
            siblings: siblings.enumerated().filter { $0.offset != index }.map(\.element),
            index: index,
            neighbor: neighbor,
            isAfterNeighbor: isAfterNeighbor,
            orientation: parent.orientation,
            layout: parent.layout,
            isRootFlattened: parent.isRootContainer && parent.children.count == 1 && neighbor is TilingContainer,
            neighborAdaptiveWeight: neighbor?.getWeight(parent.orientation) ?? WEIGHT_AUTO,
            emptiedContainer: emptiedContainer,
        )
    }

    /// The window left the root with a single container, and the root took the children and the orientation of the
    /// flattened container (see ``isRootFlattened``): they must be wrapped again before a window comes back to `root`
    @MainActor
    fileprivate func needsRootRewrap(_ root: TilingContainer) -> Bool {
        isRootFlattened && parent === root && neighbor?.parent == nil && !root.children.isEmpty &&
            (root.orientation != orientation || root.layout != layout)
    }
}

/// The neighbor of the window left the same container and is away, maybe its neighbor too, and so on: the first of
/// their neighbors that is in the tree, and the slot of the away window next to it
@MainActor
private func tilingNeighbor(ofAwayNeighborsOf slot: TilingSlot, _ isTiling: (TreeNode) -> Bool) -> (TreeNode, TilingSlot)? {
    guard let parent = slot.parent else { return nil }
    var current = slot
    for _ in 0 ..< 64 { // The windows of one container
        guard let away = current.neighbor as? Window, let awaySlot = away.tilingSlot, awaySlot.parent === parent else { return nil }
        if let node = awaySlot.neighbor, isTiling(node) { return (node, awaySlot) }
        current = awaySlot
    }
    return nil
}

/// Wraps the children that `root` took from the flattened container again (see ``TilingSlot/needsRootRewrap(_:)``), and
/// gives `root` the orientation and layout it had when the window of `slot` left
@MainActor
@discardableResult
private func rewrapRoot(_ root: TilingContainer, as slot: TilingSlot) -> TilingContainer {
    let children = root.children
    let container = TilingContainer(parent: root, adaptiveWeight: slot.neighborAdaptiveWeight, root.orientation, root.layout, index: 0)
    for child in children {
        let binding = child.unbindFromParent()
        child.bind(to: container, adaptiveWeight: binding.adaptiveWeight, index: INDEX_BIND_LAST)
    }
    root.changeOrientation(slot.orientation)
    root.layout = slot.layout
    return container
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
    for window in away where window.tilingSlot?.emptiedContainer?.container === container {
        window.tilingSlot?.emptiedContainer = nil // The tree holds the container now
    }
    container.bind(
        to: parent,
        adaptiveWeight: restoredWeight(record.adaptiveWeight, siblings: record.siblings, in: parent),
        index: insertionIndex(in: parent.children, after: record.leftSiblings),
    )
}

/// The weight of a node that comes back to `parent`: its share of `parent` when it left. The weights are proportions, so
/// the old weight means something only next to the old weights of its siblings (e.g. all of them left too, and a new
/// window started from scratch). The siblings that are gone meanwhile (closed, moved) give their share to all children,
/// the new children take theirs from all. The siblings that are still away don't count, they bring their share back
///
/// Only weights of the same time are compared: `weight` with the weights of `siblings` (the old scale), the weights of
/// the children now with each other (the new scale). The weights may have another scale now, e.g. all children left
/// and a new window started from 1
@MainActor
private func restoredWeight(_ weight: CGFloat, siblings: [WeightedSibling], in parent: TilingContainer) -> CGFloat {
    let orientation = parent.orientation
    let children = parent.inhabitedChildren
    // The first child that comes back: its weight is the scale for the others that are away
    guard !children.isEmpty else { return weight }
    let total = children.reduce(0) { $0 + max($1.getWeight(orientation), 0) }
    let away = awayNodes(of: parent)
    var before: CGFloat = 0 // The siblings that had a share when the node left (the old scale)
    var broughtBack: CGFloat = 0 // The children that were away then and came back with their own share (the new scale)
    for sibling in siblings {
        let node = sibling.node
        let isChild = node.map { $0.parent === parent && $0.tilingTreeNodeCasesOrDie().isInhabited } ?? false
        if sibling.isAway {
            if isChild, let node { broughtBack += max(node.getWeight(orientation), 0) }
        } else if isChild || !away.contains(where: { $0.node === node }) {
            before += max(sibling.weight, 0) // A child now, or gone (closed, moved): its share is free
        } // else: still away, it brings its share back itself
    }
    let now = total - broughtBack
    // The node was the only child with a share, or all children now came back with their own shares: an equal share
    guard weight > 0, before > 0, now > total * 1e-9 else { return total / CGFloat(children.count) }
    return weight * now / before
}

/// The windows of the workspace that are away in a macOS native state and have a place in its tiling tree
@MainActor
private func allAwayWindows(of workspace: Workspace) -> [Window] {
    // The existing containers only: the accessors of the workspace create them
    let containers = workspace.children.filter { $0 is MacosFullscreenWindowsContainer || $0 is MacosHiddenAppsWindowsContainer } +
        [macosMinimizedWindowsContainer] // Global
    return containers.flatMap(\.children).compactMap { $0 as? Window }.filter { $0.tilingSlot != nil }
}

/// The nodes that are away and come back to `parent`: the windows in a macOS native state, and the containers that the
/// normalization removed (see ``EmptiedContainer``)
@MainActor
private func awayNodes(of parent: TilingContainer) -> [AwayNode] {
    guard let workspace = parent.nodeWorkspace else { return [] }
    var result: [AwayNode] = []
    for window in allAwayWindows(of: workspace) {
        guard let slot = window.tilingSlot else { continue }
        if slot.parent === parent {
            result.append(AwayNode(node: window, leftSiblings: slot.leftSiblings))
        }
        if let record = slot.emptiedContainer, record.parent === parent, !result.contains(where: { $0.node === record.container }) {
            result.append(AwayNode(node: record.container, leftSiblings: record.leftSiblings))
        }
    }
    return result
}

/// The children of the container with their weights, and the nodes that are away (see ``awayNodes(of:)``) at their places
@MainActor
private func siblingsIncludingAwayNodes(_ parent: TilingContainer) -> [WeightedSibling] {
    var nodes: [TreeNode] = parent.children
    var result = nodes.map { child in
        WeightedSibling(
            node: child,
            weight: child.tilingTreeNodeCasesOrDie().isInhabited ? child.getWeight(parent.orientation) : 0,
            isAway: false,
            windows: (child as? TilingContainer)?.allLeafWindowsRecursive.map { WeakWindow(window: $0) } ?? [],
        )
    }
    let awayWindows = parent.nodeWorkspace.map(allAwayWindows(of:)) ?? []
    for away in awayNodes(of: parent) {
        let index = insertionIndex(in: nodes, after: away.leftSiblings)
        nodes.insert(away.node, at: index)
        // The windows of an emptied container are away, their slots point to it
        let windows = away.node is TilingContainer
            ? awayWindows.filter { $0.tilingSlot?.parent === away.node }.map { WeakWindow(window: $0) }
            : []
        result.insert(WeightedSibling(node: away.node, weight: 0, isAway: true, windows: windows), at: index)
    }
    return result
}

/// Right after the last of `leftSiblings` that is in `nodes`. 0 if none of them is
@MainActor
private func insertionIndex(in nodes: [TreeNode], after leftSiblings: ArraySlice<WeightedSibling>) -> Int {
    for sibling in leftSiblings.reversed() {
        // The sibling, or the child that holds it now (e.g. its neighbor came back and wrapped it in a new container), or
        // the child that holds its windows now (the normalization replaced the container)
        let candidates = [sibling.node].compactMap { $0 } + sibling.windows.compactMap(\.window)
        for candidate in candidates {
            if let index = candidate.parentsWithSelf.lazy.compactMap({ ancestor in nodes.firstIndex { $0 === ancestor } }).first {
                return index + 1
            }
        }
    }
    return 0
}
