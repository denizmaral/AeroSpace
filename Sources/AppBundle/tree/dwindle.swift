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
            return workspace.rootTilingRect
        }
        guard let parent = parent as? TilingContainer, let parentRect = parent.estimatedTilingRect(ignoring: ignored) else { return nil }
        switch parent.layout {
            case .accordion:
                return parentRect
            case .tiles:
                let siblings = parent.inhabitedChildren.filter { child in !ignored.contains { $0 === child } }
                guard let index = siblings.firstIndex(of: self) else { return nil }
                let orientation = parent.orientation
                // The same math as in layoutTiles
                let lengths = parent.proportionalLengths(siblings, total: parentRect.getDimension(orientation))
                let offset = lengths[..<index].reduce(0, +)
                let length = lengths[index]
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
/// Several windows may be detected at the same time: the callbacks of one window suspend (e.g. a title matcher reads the
/// title), and another session detects the next window meanwhile. The splits of a workspace are applied in the order of
/// capturing, and every split ignores the windows that were detected after it. The result is the same as if the windows
/// were detected one after another, unless something else changes the tree meanwhile (e.g. the callbacks of the earlier
/// window move it away: the later window was already put next to it)
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
    // The workspaces with a split that waits for its owner. Splits of other workspaces don't wait for it
    var blocked: [Workspace] = []
    var index = 0
    while index < dwindleSplitQueue.count {
        let split = dwindleSplitQueue[index]
        let workspace = split.window.nodeWorkspace
        let isBlocked = workspace.map { workspace in blocked.contains { $0 === workspace } } ?? false
        switch split.state {
            case .captured where !split.isStale: // Wait for the owner. A stale split is never applied
                if let workspace { blocked.append(workspace) }
                index += 1
            case .ready where isBlocked:
                index += 1
            case .captured, .done:
                split.state = .done
                dwindleSplitQueue.remove(at: index)
            case .ready:
                split.state = .done
                dwindleSplitQueue.remove(at: index)
                if split.isStale { continue }
                // The windows that were detected after this one don't exist yet from the point of view of the split
                let later = dwindleSplitQueue[index...].filter { $0.state != .done && !$0.isStale }.map(\.window)
                split.window.split(split.anchor, ignoring: later)
        }
    }
}

extension Window {
    /// The window was just detected and its split isn't applied yet: its place in the tree isn't the final one
    @MainActor
    var hasPendingDwindleSplit: Bool {
        dwindleSplitQueue.contains { $0.window === self && $0.state != .done && !$0.isStale }
    }

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
        // The anchor may have a later split itself (e.g. it was floated and tiled again meanwhile)
        let later = later.filter { $0 !== anchor }
        if self.parent === parent {
            // Only the windows that were detected later may be between the anchor and the window. Anything else means
            // that the tree was changed meanwhile (e.g. the user moved a window), the split doesn't apply anymore
            guard let index = ownIndex(in: .all),
                  let anchorIndex = anchor.ownIndex(in: .all),
                  anchorIndex < index,
                  parent.children[(anchorIndex + 1) ..< index].allSatisfy({ node in later.contains { $0 === node } })
            else { return }
        } else if parent.parentsWithSelf.contains(where: { $0 === self.parent }) {
            // Earlier splits put the anchor into new containers. Follow it, the same as a window that is detected after
            // the earlier windows
            unbindFromParent()
            bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: anchor.ownIndex(in: .all).orDie() + 1)
        } else {
            return // The anchor was moved elsewhere
        }
        let ignored: [TreeNode] = [self] + later

        // The anchor's rect before the window was put next to it
        let anchorRect = anchor.estimatedTilingRect(ignoring: ignored)
        let anchorOrientation: Orientation? = anchorRect.map { $0.width >= $0.height ? .h : .v }
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
        // The window may be closed while it's in a macOS native state itself: its place in the tree is in the slot
        guard let anchor = dwindleSplitAnchor,
              let (parent, weight) = (parent as? TilingContainer).map({ ($0, getWeight($0.orientation)) }) ?? tilingSlotPlace,
              parent.layout == .tiles
        else { return }
        let orientation = parent.orientation
        if anchor.parent === parent {
            anchor.setWeight(orientation, anchor.getWeight(orientation) + weight)
        } else if let anchor = anchor as? Window { // E.g. the anchor is in native fullscreen. It takes the share when it comes back
            anchor.takeShareInTilingSlot(of: self, in: parent)
        }
    }
}
