import AppKit
import Common

/// The place of a tiling window that left the tiling tree for a macOS native state (fullscreen, minimized, hidden app).
///
/// When the window leaves the native state, it comes back to the same place. Otherwise it would be placed as a new window
/// (e.g. with dwindle placement, it would split the most recent window), and every fullscreen round trip would change the
/// layout.
///
/// The container of the window is kept while the window is away, the same way as the containers of invisible windows (on
/// other macOS Spaces) are kept: the normalization doesn't flatten or remove it, it becomes a `mustBeFlattened` or
/// `deadOrInvisible` tombstone (see ``containersAwaitingWindows(of:)``). Several windows of a container may be away at
/// the same time (e.g. the app is hidden), they come back in their order whichever comes back first
struct TilingSlot {
    fileprivate weak var parent: TilingContainer?
    fileprivate var adaptiveWeight: CGFloat
    /// The siblings on the left of the window, including the windows of the container that are away themselves. The
    /// window comes back right after the last of them that is in the container
    fileprivate let leftSiblings: [WeakTreeNode]
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
                let workspace = parent.nodeWorkspace
                let siblings = childrenIncludingAwayWindows(parent)
                let previous = bind(to: container, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST).orDie()
                tilingSlot = TilingSlot(
                    parent: parent,
                    adaptiveWeight: previous.adaptiveWeight,
                    leftSiblings: siblings.prefix { $0 !== self }.map { WeakTreeNode(node: $0) },
                )
                // The container is a tombstone now. Its lifeStatus must be up to date before the next layout
                workspace?.normalizeContainers()
            case .macosFullscreenWindowsContainer, .macosHiddenAppsWindowsContainer, .macosMinimizedWindowsContainer:
                // From one macOS native state to another (e.g. the macos-native-fullscreen command binds the window to
                // the fullscreen container before the native state is detected). The window keeps its place
                bind(to: container, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
            case .floatingWindowsContainer, .macosPopupWindowsContainer, nil:
                bind(to: container, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
        }
    }

    /// Binds the window back to its place in the tiling tree of the workspace. false if the place is gone (e.g. the
    /// window comes back on another workspace, or the user flattened the tree meanwhile)
    @MainActor
    func bindBackToTilingSlot(on workspace: Workspace) -> Bool {
        guard let slot = tilingSlot else { return false }
        tilingSlot = nil
        guard let parent = slot.parent, parent.nodeWorkspace === workspace else { return false }
        parent.lifeStatus = .alive // It was a tombstone. The normalization below updates the whole tree
        bind(to: parent, adaptiveWeight: slot.adaptiveWeight, index: insertionIndex(in: parent.children, after: slot.leftSiblings))
        workspace.normalizeContainers()
        return true
    }

    /// The container and the weight of the window that is away in a macOS native state
    @MainActor
    var tilingSlotPlace: (TilingContainer, CGFloat)? {
        guard let slot = tilingSlot, let parent = slot.parent else { return nil }
        return (parent, slot.adaptiveWeight)
    }

    /// The window is away in a macOS native state, and the window that split it in dwindle placement is closed. The
    /// weight goes back to the window when it comes back. See ``returnWeightToDwindleSplitAnchor()``
    @MainActor
    func addWeightToTilingSlot(_ weight: CGFloat, of parent: TilingContainer) {
        guard tilingSlot?.parent === parent else { return }
        tilingSlot?.adaptiveWeight += weight
    }
}

/// The containers that windows in a macOS native state come back to. The normalization keeps them
@MainActor
func containersAwaitingWindows(of workspace: Workspace) -> Set<ObjectIdentifier> {
    Set(allAwayWindows(of: workspace).compactMap { $0.tilingSlot?.parent.map(ObjectIdentifier.init) })
}

/// The windows that are away in a macOS native state and have a place in a tiling tree
@MainActor
private func allAwayWindows(of workspace: Workspace) -> [Window] {
    // The existing containers only: the accessors of the workspace create them (the normalization runs in every session)
    let containers = workspace.children.filter { $0 is MacosFullscreenWindowsContainer || $0 is MacosHiddenAppsWindowsContainer } +
        [macosMinimizedWindowsContainer] // Global
    return containers.flatMap(\.children).compactMap { $0 as? Window }.filter { $0.tilingSlot != nil }
}

/// The children of the container with the windows that are away at their places
@MainActor
private func childrenIncludingAwayWindows(_ parent: TilingContainer) -> [TreeNode] {
    var result = parent.children
    guard let workspace = parent.nodeWorkspace else { return result }
    for window in allAwayWindows(of: workspace) {
        guard let slot = window.tilingSlot, slot.parent === parent else { continue }
        result.insert(window, at: insertionIndex(in: result, after: slot.leftSiblings))
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
