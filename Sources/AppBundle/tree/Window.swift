import AppKit
import Common

open class Window: TreeNode, Hashable {
    let windowId: OpaqueWindowId
    let app: any AbstractApp
    var lastFloatingSize: CGSize?
    var isFullscreen: Bool = false
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
    /// The sent frame that ``observedFrame`` was read back for: sending it again gives the same frame
    private var observedFrameRequest: SentFrame? = nil
    /// Identifies the latest knowledge about the frame: a read back of an older send is stale
    private var frameGeneration: UInt = 0
    /// The native state (minimized, fullscreen) may have changed. See normalizeLayoutReason
    var isNativeStateCheckRequested: Bool = false
    /// The place in the tiling tree before a macOS native state. See ``enterMacosNativeState(_:prevParentKind:adaptiveWeight:)``
    var tilingSlot: TilingSlot? = nil

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
        let frame = SentFrame(topLeft: topLeft, size: size)
        if frame == sentFrame { return }
        sentFrame = frame
        frameGeneration &+= 1
        // Until it's read back: what the same request gave the previous time, otherwise what is sent (most windows accept it)
        if frame != observedFrameRequest,
           let origin = topLeft ?? observedFrame?.topLeftCorner,
           let size = size ?? observedFrame?.size
        {
            setObservedFrame(Rect(topLeftX: origin.x, topLeftY: origin.y, width: size.width, height: size.height), request: nil)
        }
        sendAxFrame(topLeft, size, readBack: readBack ? frameGeneration : nil)
    }

    /// The next ``setAxFrame(_:_:readBack:)`` sends the frame even if it's the same as the previous one
    @MainActor
    final func invalidateSentFrame() {
        sentFrame = nil
        frameGeneration &+= 1 // The window may have moved since a read back that is under way
    }

    /// - Parameter generation: the send that the frame was read back for
    @MainActor
    final func frameWasReadBack(_ frame: Rect, generation: UInt) {
        guard generation == frameGeneration else { return } // Sent again or moved meanwhile: a newer read back follows
        setObservedFrame(frame, request: sentFrame)
    }

    /// - Parameter frame: read from the window just now
    @MainActor
    final func observeFrame(_ frame: Rect) {
        frameGeneration &+= 1 // Newer than a read back that is under way
        setObservedFrame(frame, request: nil)
    }

    @MainActor
    private func setObservedFrame(_ frame: Rect, request: SentFrame?) {
        observedFrameRequest = request
        if frame == observedFrame { return }
        observedFrame = frame
        FocusBorderController.shared.windowFrameDidChange(self)
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
