import AppKit
import Common

extension Workspace {
    @MainActor
    func layoutWorkspace() async throws { // todo revisit API
        if isEffectivelyEmpty { return }
        let rect = rootTilingRect
        try await layoutRecursive(rect.topLeftCorner, width: rect.width, height: rect.height, virtual: tilingRectPaddedByOuterGaps, LayoutContext(self, isInCorner: false))
    }

    /// The sizes of the tiles of the tiling windows, laid out as if the workspace was shown. While the workspace isn't
    /// shown, its windows wait in a corner of the screen with these sizes (see `MacWindow.hideInCorner`): showing it only
    /// moves them, and a window that went to the workspace meanwhile, or that MarSpace found there when it started (it
    /// had the size that it had when the previous run first saw it), isn't resized when it's shown.
    ///
    /// Sends nothing
    @MainActor
    func tileSizesWhileHidden() -> [Window: CGSize] {
        if isEffectivelyEmpty { return [:] }
        let rect = rootTilingRect
        var frames: [TiledWindowFrame] = []
        _ = rootTilingContainer.layoutTiling(
            rect.topLeftCorner,
            width: rect.width,
            height: rect.height,
            virtual: tilingRectPaddedByOuterGaps,
            LayoutContext(self, isInCorner: true),
            &frames,
        )
        return Dictionary(frames.map { ($0.window, $0.size) }, uniquingKeysWith: { _, last in last })
    }

    /// The part of the monitor for the tiling windows: without the gaps at the screen edges. A single tiling window gets
    /// the whole monitor with "no gaps around a single window" (`smartGaps`): there is nothing to tell apart
    @MainActor
    var tilingRectPaddedByOuterGaps: Rect {
        config.smartGaps && rootTilingContainer.hasSingleInhabitedWindow
            ? workspaceMonitorInfo.visibleRect
            : workspaceMonitorInfo.visibleRectPaddedByOuterGaps
    }

    /// The rect that the layout gives the root tiling container
    @MainActor
    var rootTilingRect: Rect {
        let rect = tilingRectPaddedByOuterGaps
        // If monitors are aligned vertically and the monitor below has smaller width, then macOS may not allow the
        // window on the upper monitor to take full width. rect.height - 1 resolves this problem
        // But I also faced this problem in monitors horizontal configuration. ¯\_(ツ)_/¯
        return Rect(topLeftX: rect.topLeftX, topLeftY: rect.topLeftY, width: rect.width, height: rect.height - 1)
    }
}

extension TreeNode {
    @MainActor
    fileprivate func layoutRecursive(_ point: CGPoint, width: CGFloat, height: CGFloat, virtual: Rect, _ context: LayoutContext) async throws {
        let physicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        switch nodeCases {
            case .monitor(let it):
                try await it.getWorkspacesContainerOrCreate().getVisibleWorkspaceOrCreate(parent: it)
                    .layoutRecursive(point, width: width, height: height, virtual: virtual, context)
            case .workspacesContainer: die()
            case .workspace(let workspace):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                var frames: [TiledWindowFrame] = []
                _ = workspace.rootTilingContainer.layoutTiling(point, width: width, height: height, virtual: virtual, context, &frames)
                for frame in frames {
                    if frame.isParked, let screen = context.scrollingScreen {
                        let width = frame.window.size(inTile: frame.size).width
                        frame.window.setAxFrame(frame.window.topLeftHidden(in: screen.hideCorner, width: width, of: screen.visibleRect), frame.size)
                    } else {
                        frame.window.setAxFrame(frame.shift == .zero ? frame.topLeft : frame.topLeft + frame.shift, frame.size)
                    }
                }
                try await workspace.floatingWindowsContainer.layoutRecursive(point, width: width, height: height, virtual: virtual, context)
            case .floatingWindowsContainer(let container):
                let windows = container.children.filterIsInstance(of: Window.self)
                // todo make it parallel among different workspaces. Get rid of 'try await'
                let rects = try await windows.mapConcurrently { try await $0.getAxRect(.cancellable) } // Probably not idempotent
                for (window, windowRect) in zip(windows, rects) {
                    window.lastAppliedLayoutPhysicalRect = nil
                    window.lastAppliedLayoutVirtualRect = nil
                    if let windowRect { window.observeFrame(windowRect) }
                    if let frame = window.floatingFrameToApply { // The workspace floats it, see Window.floatByWorkspaceLayout
                        window.floatingFrameToApply = nil
                        window.setAxFrame(frame.topLeftCorner, frame.size)
                    } else {
                        window.layoutFloatingWindow(context, windowRect)
                    }
                }
            case .window, .tilingContainer: die("The tiling tree is laid out by layoutTiling")
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
                return // Nothing to do for weirdos
        }
    }

    /// Gives the node of the tiling tree its tile, and collects the frames of its windows in `frames`: a container may
    /// still move them (see ``TilingContainer/layoutTiles(_:width:height:virtual:_:_:)``), they are sent afterwards
    ///
    /// - Returns: how far the windows of the node reach beyond the end of its tile (right, bottom), as far as it's known
    ///   (see ``Window/size(inTile:)``). Exactly 0 where they fill it, negative where all of them leave a part of it
    ///   free, positive where a window refuses to be as small as its tile
    @MainActor
    fileprivate func layoutTiling(
        _ point: CGPoint,
        width: CGFloat,
        height: CGFloat,
        virtual: Rect,
        _ context: LayoutContext,
        _ frames: inout [TiledWindowFrame],
    ) -> CGSize {
        let physicalRect = Rect(topLeftX: point.x, topLeftY: point.y, width: width, height: height)
        switch tilingTreeNodeCasesOrDie() {
            case .window(let window):
                if window.windowId == currentlyManipulatedWithMouseWindowId { return .zero } // Its size follows the mouse
                lastAppliedLayoutVirtualRect = virtual
                if window.isFullscreen && window == context.workspace.rootTilingContainer.mostRecentWindowRecursive {
                    lastAppliedLayoutPhysicalRect = nil
                    if context.isInCorner { // Only its size counts, the containers don't move it
                        frames.append(TiledWindowFrame(window: window, topLeft: point, size: window.fullscreenRect(context).size))
                    } else {
                        window.layoutFullscreen(context)
                    }
                    return .zero
                }
                lastAppliedLayoutPhysicalRect = physicalRect
                window.isFullscreen = false
                let tile = CGSize(width: width, height: height)
                frames.append(TiledWindowFrame(window: window, topLeft: point, size: tile))
                let size = window.size(inTile: tile)
                return CGSize(width: size.width - tile.width, height: size.height - tile.height)
            case .tilingContainer(let container):
                lastAppliedLayoutPhysicalRect = physicalRect
                lastAppliedLayoutVirtualRect = virtual
                return switch container.layout {
                    case .tiles: container.layoutTiles(point, width: width, height: height, virtual: virtual, context, &frames)
                    case .accordion: container.layoutAccordion(point, width: width, height: height, virtual: virtual, context, &frames)
                    case .scrolling: container.layoutScrolling(point, width: width, height: height, virtual: virtual, context, &frames)
                }
        }
    }
}

/// The frame of a tiling window in the layout that is being computed: its tile, and how far a container moved it
private struct TiledWindowFrame {
    let window: Window
    let topLeft: CGPoint
    let size: CGSize
    var shift: CGPoint = .zero
    /// The window is in a column of a scrolling workspace that is off the screen: it waits in a corner of the screen with
    /// the size of its tile (see ``Layout/scrolling``)
    var isParked = false
}

/// A child of a tiles container, along the orientation of the container
private struct ChildSpan {
    let tileLength: CGFloat
    /// How far its windows reach beyond the end of its tile, see ``TreeNode/layoutTiling(_:width:height:virtual:_:_:)``
    let excess: CGFloat
    /// Its windows in the frames of the layout
    let frames: Range<Int>
}

extension CGSize {
    fileprivate func along(_ orientation: Orientation) -> CGFloat { orientation == .h ? width : height }

    fileprivate init(along orientation: Orientation, _ along: CGFloat, across: CGFloat) {
        self = orientation == .h ? CGSize(width: along, height: across) : CGSize(width: across, height: along)
    }
}

extension TilingContainer {
    /// Exactly one window that is there (see ``WindowLifeStatus``), however deep
    fileprivate var hasSingleInhabitedWindow: Bool { inhabitedWindowCount(upTo: 2) == 1 }

    private func inhabitedWindowCount(upTo limit: Int) -> Int {
        var count = 0
        for child in children where count < limit {
            switch child.tilingTreeNodeCasesOrDie() {
                case .window(let window): count += window.lifeStatus.isInhabited ? 1 : 0
                case .tilingContainer(let container): count += container.inhabitedWindowCount(upTo: limit - count)
            }
        }
        return count
    }
}

private struct LayoutContext {
    let workspace: Workspace
    let gaps: Gaps
    /// The workspace isn't shown, its windows are in a corner of the screen: the layout only gives them the sizes of
    /// their tiles, and sends nothing (see ``Workspace/tileSizesWhileHidden()``)
    let isInCorner: Bool
    /// The screen of a scrolling workspace (see ``Layout/scrolling``), nil for other workspaces
    let scrollingScreen: ScrollingScreen?

    @MainActor
    init(_ workspace: Workspace, isInCorner: Bool) {
        self.workspace = workspace
        self.gaps = config.gaps
        self.isInCorner = isInCorner
        let root = workspace.rootTilingContainer
        self.scrollingScreen = root.layout == .scrolling ? ScrollingScreen(workspace.workspaceMonitorInfo, root.orientation) : nil
    }
}

/// Where the columns of a scrolling workspace that are off the screen go
private struct ScrollingScreen {
    let visibleRect: Rect
    /// The columns that are off the screen wait in this corner, like the windows of the workspaces that aren't shown
    let hideCorner: OptimalHideCorner
    /// A column can reach beyond the edge of the screen where the strip starts (left, top), or ends (right, bottom), when
    /// no other monitor is behind the edge (it would show the column there). The top edge never: macOS keeps windows
    /// below the menu bar
    let isStartEdgeFree: Bool
    let isEndEdgeFree: Bool

    @MainActor
    init(_ monitor: MonitorInfo, _ orientation: Orientation) {
        let monitors = globalUnsortedMonitorInfos
        let rect = monitor.rect
        visibleRect = monitor.visibleRect
        hideCorner = optimalHideCorner(of: monitor, among: monitors)
        func isFree(_ band: Rect) -> Bool {
            !monitors.contains { other in
                other.rect.topLeftCorner != rect.topLeftCorner &&
                    other.rect.minX < band.maxX && band.minX < other.rect.maxX &&
                    other.rect.minY < band.maxY && band.minY < other.rect.maxY
            }
        }
        switch orientation {
            case .h:
                isStartEdgeFree = isFree(Rect(topLeftX: rect.minX - rect.width, topLeftY: rect.minY, width: rect.width, height: rect.height))
                isEndEdgeFree = isFree(Rect(topLeftX: rect.maxX, topLeftY: rect.minY, width: rect.width, height: rect.height))
            case .v:
                isStartEdgeFree = false
                isEndEdgeFree = isFree(Rect(topLeftX: rect.minX, topLeftY: rect.maxY, width: rect.width, height: rect.height))
        }
    }
}

extension Window {
    @MainActor
    fileprivate func layoutFloatingWindow(_ context: LayoutContext, _ windowRect: Rect?) {
        let workspace = context.workspace
        let currentMonitor = windowRect?.center.monitorApproximation
        if let currentMonitor, let windowRect, workspace != currentMonitor.visibleWorkspace {
            let windowTopLeftCorner = windowRect.topLeftCorner
            let xProportion = (windowTopLeftCorner.x - currentMonitor.visibleRect.topLeftX) / currentMonitor.visibleRect.width
            let yProportion = (windowTopLeftCorner.y - currentMonitor.visibleRect.topLeftY) / currentMonitor.visibleRect.height

            let workspaceRect = workspace.workspaceMonitorInfo.visibleRect
            var newX = workspaceRect.topLeftX + xProportion * workspaceRect.width
            var newY = workspaceRect.topLeftY + yProportion * workspaceRect.height

            let windowWidth = windowRect.width
            let windowHeight = windowRect.height
            newX = newX.coerce(in: workspaceRect.minX ... max(workspaceRect.minX, workspaceRect.maxX - windowWidth))
            newY = newY.coerce(in: workspaceRect.minY ... max(workspaceRect.minY, workspaceRect.maxY - windowHeight))

            setAxFrame(CGPoint(x: newX, y: newY), nil)
        }
        if isFullscreen {
            layoutFullscreen(context)
            isFullscreen = false
        }
    }

    @MainActor
    fileprivate func layoutFullscreen(_ context: LayoutContext) {
        let rect = fullscreenRect(context)
        setAxFrame(rect.topLeftCorner, rect.size)
    }

    @MainActor
    fileprivate func fullscreenRect(_ context: LayoutContext) -> Rect {
        noOuterGapsInFullscreen
            ? context.workspace.workspaceMonitorInfo.visibleRect
            : context.workspace.workspaceMonitorInfo.visibleRectPaddedByOuterGaps
    }
}

extension TilingContainer {
    /// Every child gets its share of the container, its tile (see ``proportionalLengths(_:total:)``). The tiles don't
    /// depend on what the windows make of them, but a window can refuse the size of its tile: App Store is at least 1000
    /// wide and covers a part of the next tile, System Settings is at most 740 wide and leaves a part of its tile free.
    /// If the children fit into the container as they are, they are moved off each other (see
    /// ``packingShifts(_:gap:)``). No window is asked for another size than the one of its tile
    @MainActor
    fileprivate func layoutTiles(
        _ point: CGPoint,
        width: CGFloat,
        height: CGFloat,
        virtual: Rect,
        _ context: LayoutContext,
        _ frames: inout [TiledWindowFrame],
    ) -> CGSize {
        var point = point
        var virtualPoint = virtual.topLeftCorner

        let inhabitedChildren = inhabitedChildren
        guard let lastIndex = inhabitedChildren.indices.last else { return .zero }
        // The weights are proportions, the layout doesn't change them (see TilingContainer.proportionalLengths)
        let total = orientation == .h ? width : height
        lastLayoutLength = total
        let lengths = proportionalLengths(inhabitedChildren, total: total)
        let rawGap = context.gaps.inner.get(orientation).toDouble()

        var spans: [ChildSpan] = []
        spans.reserveCapacity(inhabitedChildren.count)
        var excessAcross = -CGFloat.infinity
        for (i, child) in inhabitedChildren.enumerated() {
            let length = lengths[i]
            // Gaps. Consider 4 cases:
            // 1. Multiple children. Layout first child
            // 2. Multiple children. Layout last child
            // 3. Multiple children. Layout child in the middle
            // 4. Single child   let rawGap = gaps.inner.get(orientation).toDouble()
            let gap = rawGap - (i == 0 ? rawGap / 2 : 0) - (i == lastIndex ? rawGap / 2 : 0)
            let tileLength = length - gap
            let firstFrame = frames.count
            let excess = child.layoutTiling(
                i == 0 ? point : point.addingOffset(orientation, rawGap / 2),
                width: orientation == .h ? tileLength : width,
                height: orientation == .v ? tileLength : height,
                virtual: Rect(
                    topLeftX: virtualPoint.x,
                    topLeftY: virtualPoint.y,
                    width: orientation == .h ? length : width,
                    height: orientation == .v ? length : height,
                ),
                context,
                &frames,
            )
            spans.append(ChildSpan(tileLength: tileLength, excess: excess.along(orientation), frames: firstFrame ..< frames.count))
            excessAcross = max(excessAcross, excess.along(orientation.opposite))
            virtualPoint = virtualPoint.addingOffset(orientation, length)
            point = point.addingOffset(orientation, length)
        }

        let shifts = Self.packingShifts(spans, gap: rawGap)
        // The children reach beyond the end of the container as far as the last one beyond the end of its tile, or one
        // before it beyond the tiles after it
        var excessAlong = -CGFloat.infinity
        var distanceToEnd: CGFloat = 0 // From the end of the tile of the child to the end of the container
        for (i, span) in spans.enumerated().reversed() {
            let shift = shifts?[i] ?? 0
            if shift != 0 {
                for frame in span.frames { frames[frame].shift = frames[frame].shift.addingOffset(orientation, shift) }
            }
            excessAlong = max(excessAlong, shift + span.excess - distanceToEnd)
            distanceToEnd += span.tileLength + rawGap
        }
        return CGSize(along: orientation, excessAlong, across: excessAcross)
    }

    /// How far every child of a tiles container moves along the orientation of the container, so that no child covers
    /// another one and none reaches out of the container. A child moves as little as possible, and only because of a
    /// sibling: next to the one before it if that one reaches into its tile, and back if the ones after it need the room.
    ///
    /// The tiles and the gaps between them fill the container. So the children fit into it if the free parts of the
    /// tiles make up for the parts that reach beyond them. It's computed from the excesses alone (see
    /// ``ChildSpan/excess``), which are exactly 0 for windows that fill their tiles: they never move by a rounding error.
    ///
    /// - Parameter gap: between two children
    /// - Returns: nil if no child moves: no child covers a part of the tile after it (one that reaches only into the
    ///   gap covers nothing: Terminal snaps to its character grid), or the children don't fit into the container. Then
    ///   they overlap wherever they are, and they stay at their tiles
    private static func packingShifts(_ spans: [ChildSpan], gap: CGFloat) -> [CGFloat]? {
        guard spans.contains(where: { $0.excess > gap }), spans.reduce(0, { $0 + $1.excess }) <= 0 else { return nil }
        var shifts = [CGFloat](repeating: 0, count: spans.count)
        // After the end of the child before it
        for i in spans.indices.dropFirst() {
            shifts[i] = max(0, shifts[i - 1] + spans[i - 1].excess)
        }
        // Before the start of the child after it, and the last child before the end of the container
        var limit = -spans[spans.count - 1].excess
        for i in spans.indices.reversed() {
            shifts[i] = min(shifts[i], limit)
            if i > 0 { limit = shifts[i] - spans[i - 1].excess }
        }
        return shifts
    }

    /// The children lie on top of each other on purpose: none is moved
    @MainActor
    fileprivate func layoutAccordion(
        _ point: CGPoint,
        width: CGFloat,
        height: CGFloat,
        virtual: Rect,
        _ context: LayoutContext,
        _ frames: inout [TiledWindowFrame],
    ) -> CGSize {
        let inhabitedChildren = inhabitedChildren

        guard let mruIndex: Int = mostRecentInhabitedChild?.ownIndex(in: .inhabitedOnly) else { return .zero }
        var excessAlong = -CGFloat.infinity
        var excessAcross = -CGFloat.infinity
        for (index, child) in inhabitedChildren.enumerated() {
            let padding = CGFloat(config.accordionPadding)
            let (lPadding, rPadding): (CGFloat, CGFloat) = switch index {
                case 0 where inhabitedChildren.count == 1: (0, 0)
                case 0:                                (0, padding)
                case inhabitedChildren.indices.last:   (padding, 0)
                case mruIndex - 1:                     (0, 2 * padding)
                case mruIndex + 1:                     (2 * padding, 0)
                default:                               (padding, padding)
            }
            let excess = switch orientation {
                case .h:
                    child.layoutTiling(
                        point + CGPoint(x: lPadding, y: 0),
                        width: width - rPadding - lPadding,
                        height: height,
                        virtual: virtual,
                        context,
                        &frames,
                    )
                case .v:
                    child.layoutTiling(
                        point + CGPoint(x: 0, y: lPadding),
                        width: width,
                        height: height - lPadding - rPadding,
                        virtual: virtual,
                        context,
                        &frames,
                    )
            }
            // The tile of the child ends `rPadding` before the end of the accordion
            excessAlong = max(excessAlong, excess.along(orientation) - rPadding)
            excessAcross = max(excessAcross, excess.along(orientation.opposite))
        }
        return CGSize(along: orientation, excessAlong, across: excessAcross)
    }
}

extension TilingContainer {
    /// The columns of a scrolling workspace (see ``Layout/scrolling``): side by side on a strip, the screen shows the part
    /// of it with the most recent column. A column that is partly off the screen reaches beyond the edge of the screen
    /// if no other monitor is behind it, otherwise it's squeezed into the part that is on the screen. A column that is
    /// off the screen waits in a corner of the screen with its size, like the windows of a workspace that isn't shown
    @MainActor
    fileprivate func layoutScrolling(
        _ point: CGPoint,
        width: CGFloat,
        height: CGFloat,
        virtual: Rect,
        _ context: LayoutContext,
        _ frames: inout [TiledWindowFrame],
    ) -> CGSize {
        let columns = inhabitedChildren
        guard !columns.isEmpty, let screen = context.scrollingScreen else { return .zero }
        let screenLength = orientation == .h ? width : height
        let gap = context.gaps.inner.get(orientation).toDouble()
        let stripLength = scrollingStripLength(screen: screenLength)
        lastLayoutLength = stripLength
        let strip = ScrollingStrip(lengths: childLengths(columns, total: stripLength), screen: screenLength, gap: gap)
        let focused = mostRecentInhabitedChild.flatMap { columns.firstIndex(of: $0) } ?? 0
        scrollOffset = strip.offset(showing: focused, from: scrollOffset)
        let placements = strip.placements(offset: scrollOffset, isStartEdgeFree: screen.isStartEdgeFree, isEndEdgeFree: screen.isEndEdgeFree)

        var excessAcross = -CGFloat.infinity
        for (column, placement) in zip(columns, placements) {
            let (start, length, isParked) = switch placement {
                case .tile(let start, let length): (start, length, false)
                case .parked(let start, let length): (start, length, true)
            }
            let firstFrame = frames.count
            let excess = column.layoutTiling(
                point.addingOffset(orientation, start),
                width: orientation == .h ? length : width,
                height: orientation == .v ? length : height,
                virtual: Rect(
                    topLeftX: orientation == .h ? point.x + start - gap / 2 : virtual.topLeftX,
                    topLeftY: orientation == .v ? point.y + start - gap / 2 : virtual.topLeftY,
                    width: orientation == .h ? length + gap : virtual.width,
                    height: orientation == .v ? length + gap : virtual.height,
                ),
                context,
                &frames,
            )
            if isParked {
                for frame in firstFrame ..< frames.count { frames[frame].isParked = true }
                column.forgetAppliedLayoutRecursive() // Nothing of it is on the screen: not a target of the mouse
            } else {
                excessAcross = max(excessAcross, excess.along(orientation.opposite))
            }
        }
        // The strip is as long as the columns want, nothing reaches beyond its end
        return CGSize(along: orientation, 0, across: excessAcross)
    }
}

extension TreeNode {
    @MainActor
    fileprivate func forgetAppliedLayoutRecursive() {
        lastAppliedLayoutPhysicalRect = nil
        lastAppliedLayoutVirtualRect = nil
        for child in children { child.forgetAppliedLayoutRecursive() }
    }
}

/// Where a column of a scrolling container goes along the orientation, from the start of the screen
enum ScrollingColumnPlacement: Equatable {
    /// On the screen, or partly beyond an edge of it
    case tile(start: CGFloat, length: CGFloat)
    /// Off the screen: it waits in a corner of the screen, with the size of its tile
    case parked(start: CGFloat, length: CGFloat)
}

/// The columns of a scrolling container on their strip (see ``Layout/scrolling``). A column is its tile and half a gap on
/// each side, so the strip shows `screen` and a gap: the gaps at the ends of the strip are off the screen. Columns that
/// fit on the screen are laid out like tiles
struct ScrollingStrip {
    /// Of the columns, with their gaps
    let lengths: [CGFloat]
    let screen: CGFloat
    let gap: CGFloat

    /// The offset that shows the column at `index` whole, as close to `previous` as possible: the screen moves only as
    /// far as needed, and never beyond the ends of the strip
    func offset(showing index: Int, from previous: CGFloat) -> CGFloat {
        let visible = screen + gap
        let total = lengths.reduce(0, +)
        var offset = previous
        if lengths.indices.contains(index) {
            let start = lengths[..<index].reduce(0, +)
            let end = start + lengths[index]
            if start < offset { offset = start }
            if end > offset + visible { offset = end - visible }
        }
        return offset.coerce(in: 0 ... max(0, total - visible))
    }

    /// - Parameter isStartEdgeFree: a column can reach beyond the edge of the screen where the strip starts: no monitor is
    ///   behind it. Otherwise a column that is partly off the screen there is squeezed into the part that is on the
    ///   screen, if that's at least a third of it
    func placements(offset: CGFloat, isStartEdgeFree: Bool, isEndEdgeFree: Bool) -> [ScrollingColumnPlacement] {
        var result: [ScrollingColumnPlacement] = []
        result.reserveCapacity(lengths.count)
        var position = -offset
        for length in lengths {
            let tile = max(length - gap, 0)
            let start = position
            let end = start + tile
            position += length
            if start >= -0.5 && end <= screen + 0.5 {
                result.append(.tile(start: start, length: tile))
                continue
            }
            let visibleStart = max(start, 0)
            let visibleLength = min(end, screen) - visibleStart
            let isCutAtStart = start < 0
            if visibleLength <= 0 {
                result.append(.parked(start: start, length: tile))
            } else if isCutAtStart ? isStartEdgeFree : isEndEdgeFree {
                result.append(.tile(start: start, length: tile))
            } else if visibleLength * 3 >= tile {
                result.append(.tile(start: visibleStart, length: visibleLength))
            } else {
                result.append(.parked(start: start, length: tile))
            }
        }
        return result
    }
}
