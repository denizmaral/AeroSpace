import AppKit
import Common

final class TilingContainer: TreeNode, NonLeafTreeNodeObject { // todo consider renaming to GenericContainer
    fileprivate var _orientation: Orientation
    private var _layout: Layout
    var lifeStatus: TilingContainerLifeStatus = .alive // todo tighten its visibility
    /// The length that the last layout shared among the children (along the orientation). See ``pixelsToWeight(_:)``
    var lastLayoutLength: CGFloat? = nil
    /// The part of the strip of columns that a scrolling container shows: how far its start is from the start of the
    /// first column (see ``Layout/scrolling``)
    var scrollOffset: CGFloat = 0

    var orientation: Orientation { _orientation }
    var layout: Layout {
        get { _layout }
        set(value) {
            if isDebug && lifeStatus != .alive { die("Can't change layout of not alive TilingContainer") }
            _layout =  value
        }
    }

    func copyFrom(_ other: TilingContainer) {
        self._orientation = other.orientation
        self._layout = other.layout
        self.lifeStatus = other.lifeStatus
    }

    @MainActor
    init(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, _ orientation: Orientation, _ layout: Layout, index: Int) {
        self._orientation = orientation
        self._layout = layout
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor
    static func newHTiles(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> TilingContainer {
        TilingContainer(parent: parent, adaptiveWeight: adaptiveWeight, .h, .tiles, index: index)
    }

    @MainActor
    static func newVTiles(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> TilingContainer {
        TilingContainer(parent: parent, adaptiveWeight: adaptiveWeight, .v, .tiles, index: index)
    }
}

extension TilingContainer {
    var isRootContainer: Bool { parent is Workspace }

    @MainActor
    func changeOrientation(_ targetOrientation: Orientation) {
        if orientation == targetOrientation {
            return
        }
        if config.enableNormalizationOppositeOrientationForNestedContainers {
            parentsWithSelf
                .filterIsInstance(of: TilingContainer.self)
                .forEach { $0._orientation.flip() }
        } else {
            _orientation = targetOrientation
        }
    }

    func normalizeOppositeOrientationForNestedContainersRecursive(parentOrientation: Orientation?) {
        switch lifeStatus {
            case .deadOrInvisible: return
            case .alive: _orientation = parentOrientation?.opposite ?? orientation
            case .mustBeFlattened: _orientation = parentOrientation ?? orientation
        }
        for child in children {
            (child as? TilingContainer)?.normalizeOppositeOrientationForNestedContainersRecursive(parentOrientation: orientation)
        }
    }
}

enum Layout: String {
    case tiles
    case accordion
    /// Hyprland's and niri's scrolling layout, only for the root container of a workspace: the children are columns
    /// side by side on a strip that can be longer than the screen. A column is as long as its weight times the column
    /// length (``Config/scrollingColumnWidth`` of the screen), the others keep their lengths when one is resized. The
    /// screen shows the part of the strip with the most recent column (``TilingContainer/scrollOffset``), the columns
    /// that are off the screen wait in a corner of it. Columns that fit on the screen together share it (one column
    /// fills it)
    case scrolling
}

// The weights of the children of a tiles container are proportions: the layout gives every child its share of the
// length of the container (see ``proportionalLengths(_:total:)``), and it never changes the weights. A window that leaves
// the container and comes back (e.g. native fullscreen) gets exactly the same size again, the others keep theirs.
// Commands that size windows in pixels (resize, mouse) convert pixels to weights with ``pixelsToWeight(_:)``.
//
// The weights of the columns of a scrolling container are lengths: a weight of 1 is the column length (see
// ``Layout/scrolling``)
extension TilingContainer {
    /// The lengths of `children` (along the orientation) that share `total` in the proportions of their weights
    @MainActor
    func proportionalLengths(_ children: [TreeNode], total: CGFloat) -> [CGFloat] {
        let weights = children.map { max($0.getWeight(orientation), 0) }
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return weights.map { _ in total / CGFloat(max(weights.count, 1)) } }
        return weights.map { total * $0 / sum }
    }

    /// The lengths of `children` in the container when it's `total` long: the shares of a tiles container, the column
    /// lengths of a scrolling container. Not for accordions, whose children are as long as the container
    @MainActor
    func childLengths(_ children: [TreeNode], total: CGFloat) -> [CGFloat] {
        switch layout {
            case .tiles, .accordion: return proportionalLengths(children, total: total)
            case .scrolling:
                let unit = total * config.scrollingColumnWidth
                let lengths = children.map { min(max($0.getWeight(orientation), 0) * unit, total) }
                // Columns that fit share the screen, nothing is left empty (one column fills it)
                return lengths.reduce(0, +) <= total + 0.5 ? proportionalLengths(children, total: total) : lengths
        }
    }

    /// The length that the columns of a scrolling container share when they fit on the screen: the screen and one
    /// inner gap. Every column is a tile and its gap (half a gap on each side), the gaps at the ends are off the screen
    @MainActor
    func scrollingStripLength(screen: CGFloat) -> CGFloat {
        screen + CGFloat(config.gaps.inner.get(orientation))
    }

    /// The length of a column with weight 1 in a scrolling container (see ``Layout/scrolling``), in ``sharedLength``
    @MainActor
    var scrollingColumnLength: CGFloat? { sharedLength.map { $0 * config.scrollingColumnWidth } }

    /// The length (along the orientation) that the children share: the length of the last layout. A container that
    /// wasn't laid out yet (e.g. created in this session), or a workspace that isn't visible (the monitor may have
    /// changed): estimated from the tree
    @MainActor
    var sharedLength: CGFloat? {
        if let lastLayoutLength, nodeWorkspace?.isVisible == true { return lastLayoutLength }
        let estimated = estimatedTilingRect()?.getDimension(orientation)
        return layout == .scrolling ? estimated.map(scrollingStripLength(screen:)) : estimated
    }

    /// The weight that corresponds to `pixels` of ``sharedLength``
    @MainActor
    func pixelsToWeight(_ pixels: CGFloat) -> CGFloat {
        if layout == .scrolling { // The weights are lengths
            guard let length = sharedLength, length > 0 else { return pixels }
            return pixels / (length * config.scrollingColumnWidth)
        }
        let sum = inhabitedChildren.reduce(0) { $0 + max($1.getWeight(orientation), 0) }
        guard let length = sharedLength, length > 0, sum > 0 else { return pixels }
        return pixels * sum / length
    }

    /// The length of `child` (along the orientation) in ``sharedLength``
    @MainActor
    func length(of child: TreeNode) -> CGFloat? {
        if layout == .scrolling {
            let children = inhabitedChildren
            guard let length = sharedLength, let index = children.firstIndex(of: child) else { return nil }
            return childLengths(children, total: length)[index]
        }
        let sum = inhabitedChildren.reduce(0) { $0 + max($1.getWeight(orientation), 0) }
        guard let length = sharedLength, sum > 0 else { return nil }
        return length * max(child.getWeight(orientation), 0) / sum
    }
}
