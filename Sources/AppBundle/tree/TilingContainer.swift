import AppKit
import Common

final class TilingContainer: TreeNode, NonLeafTreeNodeObject { // todo consider renaming to GenericContainer
    fileprivate var _orientation: Orientation
    private var _layout: Layout
    var lifeStatus: TilingContainerLifeStatus = .alive // todo tighten its visibility
    /// The length that the last layout shared among the children (along the orientation). See ``pixelsToWeight(_:)``
    var lastLayoutLength: CGFloat? = nil

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
}

extension String {
    func parseLayout() -> Layout? {
        switch Layout(rawValue: self) {
            case let parsed?: parsed
            case nil where self == "list": .tiles
            case nil: nil
        }
    }
}

// The weights of the children of a tiles container are proportions: the layout gives every child its share of the
// length of the container (see ``proportionalLengths(_:total:)``), and it never changes the weights. A window that leaves
// the container and comes back (e.g. native fullscreen) gets exactly the same size again, the others keep theirs.
// Commands that size windows in pixels (resize, mouse) convert pixels to weights with ``pixelsToWeight(_:)``
extension TilingContainer {
    /// The lengths of `children` (along the orientation) that share `total` in the proportions of their weights
    @MainActor
    func proportionalLengths(_ children: [TreeNode], total: CGFloat) -> [CGFloat] {
        let weights = children.map { max($0.getWeight(orientation), 0) }
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return weights.map { _ in total / CGFloat(max(weights.count, 1)) } }
        return weights.map { total * $0 / sum }
    }

    /// The length (along the orientation) that the children share: the length of the last layout. A container that
    /// wasn't laid out yet (e.g. created in this session), or a workspace that isn't visible (the monitor may have
    /// changed): estimated from the tree
    @MainActor
    var sharedLength: CGFloat? {
        if let lastLayoutLength, nodeWorkspace?.isVisible == true { return lastLayoutLength }
        return estimatedTilingRect()?.getDimension(orientation)
    }

    /// The weight that corresponds to `pixels` of ``sharedLength``
    @MainActor
    func pixelsToWeight(_ pixels: CGFloat) -> CGFloat {
        let sum = inhabitedChildren.reduce(0) { $0 + max($1.getWeight(orientation), 0) }
        guard let length = sharedLength, length > 0, sum > 0 else { return pixels }
        return pixels * sum / length
    }

    /// The length of `child` (along the orientation) in ``sharedLength``
    @MainActor
    func length(of child: TreeNode) -> CGFloat? {
        let sum = inhabitedChildren.reduce(0) { $0 + max($1.getWeight(orientation), 0) }
        guard let length = sharedLength, sum > 0 else { return nil }
        return length * max(child.getWeight(orientation), 0) / sum
    }
}
