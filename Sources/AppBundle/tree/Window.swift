import AppKit
import Common

open class Window: TreeNode, Hashable {
    let windowId: OpaqueWindowId
    let app: any AbstractApp
    var lastFloatingSize: CGSize?
    var isFullscreen: Bool = false
    /// A pinned floating window is on the workspace that its monitor shows. See ``PinCommand``
    var isPinned: Bool = false
    var noOuterGapsInFullscreen: Bool = false
    var layoutReason: LayoutReason = .standard
    var lifeStatus: WindowLifeStatus = .alive
    /// The sibling that gave half of its weight to this window (see `applyDwindleSplit`). It takes the weight back on close
    weak var dwindleSplitAnchor: TreeNode? = nil
    /// See ``setAxFrame(_:_:readBack:)``
    private var sentFrame: SentFrame? = nil
    /// Where the window is on the screen, as far as AeroSpace knows, without accessibility calls. Unlike the tile
    /// (``lastAppliedLayoutPhysicalRect``: the place in the tree), it's what the user sees: a window refuses a size
    /// smaller than its minimum (App Store is at least 1000 wide), or snaps to its character grid (Terminal).
    ///
    /// The frame that was sent, corrected when it's read back in the same accessibility job (``frameWasReadBack(_:generation:)``).
    /// Floating windows are read by every layout (``observeFrame(_:)``). Code that deals with the screen (the focus
    /// border, focus-follows-mouse) uses it, the layout and the tree commands use the tile
    private(set) var observedFrame: Rect? = nil
    /// What the window made of the last two sizes that it was asked for: an app can refuse a size (App Store is at least
    /// 1000 wide, System Settings at most 740). Asking for the same size again gives the same answer, wherever the window
    /// is (e.g. after a workspace switch hid it in a corner of the screen). Two: the size of its tile comes back after
    /// macOS fullscreen, or after a window was opened next to it and closed again. See ``size(inTile:)``
    private var sizeAnswers: (latest: SizeAnswer?, previous: SizeAnswer?) = (nil, nil)
    /// The refresh sessions that were asked for in a row because of what the window made of its tile. See
    /// ``rememberSizeAnswer(asked:got:at:)``
    private var layoutRequestsAfterReadBack: (count: Int, last: ContinuousClock.Instant)? = nil
    /// Identifies the latest knowledge about the frame: a read back of an older send is stale
    private var frameGeneration: UInt = 0
    /// The native state (minimized, fullscreen) may have changed. See normalizeLayoutReason
    var isNativeStateCheckRequested: Bool = false
    /// The place in the tiling tree before a macOS native state. See ``enterMacosNativeState(_:prevParentKind:adaptiveWeight:)``
    var tilingSlot: TilingSlot? = nil
    /// The window floats because its workspace floats (see ``WorkspaceLayout/floating``): it's a tile again when the
    /// workspace tiles or scrolls, or when it's moved to a workspace that does. Not a window that floats on its own
    /// account (a dialog, `layout floating`)
    var isFloatedByWorkspaceLayout = false
    /// The user made the window a tile on this floating workspace (`layout tiling`): it stays a tile there
    weak var tiledOnFloatingWorkspace: Workspace? = nil
    /// The frame that the floating layout gives the window when its workspace is shown, see ``floatByWorkspaceLayout(on:)``
    var floatingFrameToApply: Rect? = nil
    /// Where the window was when its workspace stopped floating: it goes back there when the workspace floats again
    var floatingFrameOfWorkspaceLayout: Rect? = nil

    @MainActor
    init(id: OpaqueWindowId, _ app: any AbstractApp, lastFloatingSize: CGSize?, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) {
        self.windowId = id
        self.app = app
        self.lastFloatingSize = lastFloatingSize
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor static func get(byId windowId: OpaqueWindowId) -> Window? { // todo make non optional
        isUnitTest
            ? Workspace.all.flatMap { $0.allLeafWindowsRecursive }.first(where: { $0.windowId == windowId })
            : MacWindow.allWindowsMap[windowId]
    }

    @MainActor static func get(byNativeId nativeWindowId: UInt32, pid: pid_t) -> Window? {
        MacApp.allAppsMap[pid]?.opaqueWindowId(of: nativeWindowId).flatMap { get(byId: $0) }
    }

    @MainActor
    func closeAxWindow() { die("Not implemented") }

    @MainActor
    @discardableResult
    override func bind(to newParent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> BindingData? {
        // Placed somewhere else (e.g. moved by a command) while in a macOS native state: it doesn't go back to its old place
        if tilingSlot != nil,
           !(newParent is MacosFullscreenWindowsContainer || newParent is MacosHiddenAppsWindowsContainer || newParent is MacosMinimizedWindowsContainer)
        {
            tilingSlot = nil
        }
        if newParent is TilingContainer { isPinned = false } // Tiled: it has its place in the layout of one workspace
        return super.bind(to: newParent, adaptiveWeight: adaptiveWeight, index: index)
    }

    /// Unbinds the window that was closed
    @MainActor
    @discardableResult
    final func unbindAsClosed() -> BindingData {
        returnWeightToDwindleSplitAnchor()
        return unbindFromParent()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(windowId)
    }

    func getAxSize(_ cm: CancellationMode) async throws -> CGSize? { die("Not implemented") }
    func getTitle(_ cm: CancellationMode) async throws -> String { die("Not implemented") }

    func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { false }
    func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { false }
    func getMacosWindowNativeState(_ cm: CancellationMode) async throws -> MacosWindowNativeState {
        if try await isMacosFullscreen(cm) { return .nativeFullscreen }
        if try await isMacosMinimized(cm) { return .nativeMinimized }
        return .normal
    }

    var isHiddenInCorner: Bool { die("Not implemented") }

    /// Where the top left corner of the window goes to hide it in `corner` of `visibleRect` (see `MacWindow.hideInCorner`)
    /// - Parameter width: of the window, for the bottom left corner: its right edge is at the left edge of the screen
    func topLeftHidden(in corner: OptimalHideCorner, width: CGFloat, of visibleRect: Rect) -> CGPoint {
        switch corner {
            case .bottomLeftCorner: visibleRect.bottomLeftCorner + CGPoint(x: 1 - width, y: -1)
            case .bottomRightCorner: visibleRect.bottomRightCorner - CGPoint(x: 1, y: 1)
        }
    }
    @MainActor func nativeFocus() { die("Not implemented") }
    func getAxRect(_ cm: CancellationMode) async throws -> Rect? { die("Not implemented") }
    func getCenter(_ cm: CancellationMode) async throws -> CGPoint? { try await getAxRect(cm)?.center }

    /// Sends the frame to the window, unless exactly the same frame was already sent.
    ///
    /// The layout runs at the end of every refresh session, and most of the time nothing changes. Each send costs
    /// several accessibility round trips to the app (and wakes the app up), so unchanged frames are skipped. The sent
    /// frame is forgotten (``invalidateSentFrame()``) whenever the window may have been moved or resized by somebody
    /// else: AX moved/resized notifications, failed AX writes, app activation, Space/display changes, wake, etc.
    ///
    /// - Parameter readBack: read the frame back after it's applied, see ``observedFrame``. Not needed for a window that
    ///   is hidden in a corner of the screen
    @MainActor
    final func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?, readBack: Bool = true) {
        // Placed by something else (e.g. hidden with its workspace, made floating): a slide doesn't take it back
        if !ScrollAnimation.isWriting { ScrollAnimation.stop(self) }
        let frame = SentFrame(topLeft: topLeft, size: size)
        if frame == sentFrame { return }
        sentFrame = frame
        frameGeneration &+= 1
        // Until it's read back: what the window is expected to make of it
        // The layout runs in a refresh session, which updates the focus border at its end
        if let origin = topLeft ?? observedFrame?.topLeftCorner, let size = size.map(answer(to:)) ?? observedFrame?.size {
            setObservedFrame(Rect(topLeftX: origin.x, topLeftY: origin.y, width: size.width, height: size.height), updatesFocusBorder: false)
        }
        sendAxFrame(topLeft, size, readBack: readBack ? frameGeneration : nil)
    }

    /// What the window makes of `size`, as far as it's known: its answer the last time, otherwise `size` itself (most
    /// windows accept it)
    private func answer(to size: CGSize) -> CGSize {
        if let latest = sizeAnswers.latest, latest.asked == size { return latest.got }
        if let previous = sizeAnswers.previous, previous.asked == size { return previous.got }
        return size
    }

    private func remember(_ answer: SizeAnswer) {
        if sizeAnswers.latest?.asked != answer.asked { sizeAnswers.previous = sizeAnswers.latest }
        sizeAnswers.latest = answer
    }

    /// The size of the window when the layout asks it for the size of its tile, as far as it's known (see
    /// ``answer(to:)``). A difference below a point is rounding (tiles aren't whole points), not a refused size: the
    /// size of the tile itself then, exactly
    final func size(inTile tile: CGSize) -> CGSize {
        let got = answer(to: tile)
        return CGSize(
            width: abs(got.width - tile.width) < 1 ? tile.width : got.width,
            height: abs(got.height - tile.height) < 1 ? tile.height : got.height,
        )
    }

    /// The window reaches beyond the gap after its tile, as far as it's known: it covers a part of the tile next to it.
    /// Windows are moved off each other only then (see `TilingContainer.layoutTiles`). A window that reaches only into
    /// the gap covers nothing (Terminal snaps to its character grid)
    @MainActor
    final var isBiggerThanTile: Bool {
        guard let tile = lastAppliedLayoutPhysicalRect?.size else { return false }
        let size = size(inTile: tile)
        let gaps = config.gaps.inner
        return size.width - tile.width > CGFloat(gaps.horizontal) || size.height - tile.height > CGFloat(gaps.vertical)
    }

    /// The next ``setAxFrame(_:_:readBack:)`` sends the frame even if it's the same as the previous one
    @MainActor
    final func invalidateSentFrame() {
        sentFrame = nil
        frameGeneration &+= 1 // The window may have moved since a read back that is under way
    }

    /// - Parameter generation: the send that the frame was read back for
    @MainActor
    final func frameWasReadBack(_ frame: Rect, generation: UInt, at now: ContinuousClock.Instant = .now) {
        guard generation == frameGeneration else { return } // Sent again or moved meanwhile: a newer read back follows
        if let asked = sentFrame?.size { rememberSizeAnswer(asked: asked, got: frame.size, at: now) }
        // It arrives after the session that sent the frame (it doesn't matter if another session is running)
        setObservedFrame(frame, updatesFocusBorder: true)
    }

    /// An app is expected to make the same of the same size every time. A window that doesn't isn't followed forever:
    /// every layout that moves it would ask for the next one. After a quiet second, it's followed again
    private static let maxLayoutRequestsAfterReadBack = 3
    private static let layoutRequestsAfterReadBackQuietInterval: Duration = .seconds(1)

    /// The layout that sent the frame didn't know the answer yet, or the window changed its mind: the windows are laid
    /// out again if that can move one of them. Windows are moved only around a window that is bigger than its tile, so
    /// a window that is only smaller than its tile, or reaches only into the gap after it (Terminal snaps to its
    /// character grid), doesn't cost a refresh session
    @MainActor
    private func rememberSizeAnswer(asked: CGSize, got: CGSize, at now: ContinuousClock.Instant) {
        let assumed = size(inTile: asked)
        let wasBiggerThanTile = isBiggerThanTile
        remember(SizeAnswer(asked: asked, got: got))
        guard lastAppliedLayoutPhysicalRect?.size == asked, size(inTile: asked) != assumed else { return }
        guard wasBiggerThanTile || nodeWorkspace?.rootTilingContainer.allLeafWindowsRecursive
            .contains(where: { $0.lifeStatus.isInhabited && $0.isBiggerThanTile }) == true
        else { return }
        let inARow = layoutRequestsAfterReadBack
            .flatMap { now - $0.last < Self.layoutRequestsAfterReadBackQuietInterval ? $0.count : nil } ?? 0
        guard inARow < Self.maxLayoutRequestsAfterReadBack else { return }
        layoutRequestsAfterReadBack = (inARow + 1, now)
        scheduleCancellableCompleteRefreshSession(.frameReadBack)
    }

    /// - Parameter frame: read from the window just now
    @MainActor
    final func observeFrame(_ frame: Rect) {
        frameGeneration &+= 1 // Newer than a read back that is under way
        setObservedFrame(frame, updatesFocusBorder: false) // Read by the layout, in a refresh session
    }

    @MainActor
    private func setObservedFrame(_ frame: Rect, updatesFocusBorder: Bool) {
        if frame == observedFrame { return }
        observedFrame = frame
        if updatesFocusBorder { FocusBorderController.shared.windowFrameDidChange(self) }
    }

    /// Use ``setAxFrame(_:_:readBack:)``
    ///
    /// - Parameter readBack: the generation to report the frame with to ``frameWasReadBack(_:generation:)``, nil if
    ///   it's not needed
    @MainActor
    func sendAxFrame(_ topLeft: CGPoint?, _ size: CGSize?, readBack: UInt?) { die("Not implemented") }
}

// periphery:ignore - the properties are only compared (Equatable)
private struct SentFrame: Equatable {
    let topLeft: CGPoint?
    let size: CGSize?
}

/// What a window made of a size that it was asked for, see `Window.sizeAnswers`
private struct SizeAnswer {
    let asked: CGSize
    let got: CGSize
}

enum MacosWindowNativeState: Sendable {
    case normal
    case nativeMinimized
    case nativeFullscreen
}

enum LayoutReason: Equatable {
    case standard
    /// Reason for the cur temp layout is macOS native fullscreen, minimize, or hide
    case macos(prevParentKind: WindowParentCases.Kind)
}

extension Window {
    var isFloating: Bool { // todo drop. It will be a source of bugs when sticky is introduced
        switch windowParentCases {
            case .floatingWindowsContainer: true
            case .macosFullscreenWindowsContainer: false
            case .macosHiddenAppsWindowsContainer: false
            case .macosMinimizedWindowsContainer: false
            case .macosPopupWindowsContainer: false
            case .tilingContainer: false
            case nil: false
        }
    }

    @discardableResult
    @MainActor
    func bindAsFloatingWindow(to workspace: Workspace) -> BindingData? {
        bind(to: workspace.floatingWindowsContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
    }

    func asMacWindow() -> MacWindow { self as! MacWindow }
}
