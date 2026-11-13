import AppKit
import Common

struct ResizeCommand: Command {
    let args: ResizeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        guard let target = args.resolveTargetOrReportError(env, io) else { return .fail }

        let candidates = target.windowOrNil?.parentsWithSelf
            .filter { ($0.parent as? TilingContainer)?.layout != .accordion }
            .filter {
                guard let parent = $0.parent as? TilingContainer else { return false }
                return switch parent.lifeStatus {
                    case .alive: true
                    case .mustBeFlattened, .deadOrInvisible: false
                }
            }
            ?? []

        let orientation: Orientation?
        let parent: TilingContainer?
        let node: TreeNode?
        switch args.dimension.val {
            case .width:
                orientation = .h
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .height:
                orientation = .v
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .smart:
                node = candidates.first
                parent = node?.parent as? TilingContainer
                orientation = parent?.orientation
            case .smartOpposite:
                orientation = (candidates.first?.parent as? TilingContainer)?.orientation.opposite
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
        }
        guard let parent else {
            return .fail(io.err("resize command doesn't support floating windows yet"))
        }
        guard let orientation else { return .fail }
        guard let node else { return .fail }
        // The units are pixels, the weights are proportions (see TilingContainer.pixelsToWeight)
        let length = parent.length(of: node) ?? node.getWeight(orientation)
        let pixels: CGFloat = switch args.units.val {
            case .set(let unit): CGFloat(unit) - length
            case .add(let unit): CGFloat(unit)
            case .subtract(let unit): -CGFloat(unit)
        }
        if parent.layout == .scrolling { // A column is resized alone, the others keep their lengths
            guard let unit = parent.scrollingColumnLength, unit > 0, let strip = parent.sharedLength else { return .fail }
            // From a twentieth of the screen to all of it
            node.setWeight(orientation, (length + pixels).coerce(in: strip * 0.05 ... strip) / unit)
            return .succ
        }
        let inhabitedSiblings = parent.inhabitedChildren.filter { $0 != node }
        // Nobody is resized to nothing: a tile keeps a twentieth of the container (half of its equal share, if that's
        // less). Weights below zero were laid out as nothing, and it took as many steps back to see the window again
        let weights = (inhabitedSiblings + [node]).map { max($0.getWeight(orientation), 0) }
        let minimum = weights.reduce(0, +) * min(0.05, 0.5 / CGFloat(weights.count))
        let maxGrowth = max((weights.dropLast().min() ?? 0) - minimum, 0) * CGFloat(inhabitedSiblings.count)
        let maxShrinkage = max(node.getWeight(orientation) - minimum, 0)
        let diff = min(max(parent.pixelsToWeight(pixels), -maxShrinkage), maxGrowth)

        guard let childDiff = diff.div(inhabitedSiblings.count) else { return .fail }
        for sibling in inhabitedSiblings {
            sibling.setWeight(parent.orientation, sibling.getWeight(parent.orientation) - childDiff)
        }

        node.setWeight(orientation, node.getWeight(orientation) + diff)
        return .succ
    }
}
