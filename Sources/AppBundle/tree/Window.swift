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
    /// The rect of the floating window as of the last layout. Allows hit testing without accessibility calls
    var lastLayoutFloatingRect: Rect? = nil
    /// See ``setAxFrame(_:_:)``
    private var sentFrame: SentFrame? = nil
    /// The size that the window refused to shrink below. Zero if unknown. Use `effectiveMinimumSize`. See minimumSize.swift
    var learnedMinimumSize: CGSize = .zero
    /// The workspace where the minimum size was learned (nil: any)
    var learnedMinimumSizeWorkspace: String? = nil
    var minimumSizeCheckTask: Task<(), any Error>? = nil
    var isMinimumSizeRecheckRequested: Bool = false
    var isMinimumSizeRecheckAfterLayoutRequested: Bool = false
    /// The native state (minimized, fullscreen) may have changed. See normalizeLayoutReason
    var isNativeStateCheckRequested: Bool = false

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
        let result = super.bind(to: newParent, adaptiveWeight: adaptiveWeight, index: index)
        // Another workspace. Global containers (e.g. minimized windows) don't count, the window comes back
        if let learned = learnedMinimumSizeWorkspace, let workspace = nodeWorkspace?.name, workspace != learned {
            forgetMinimumSize() // See forgetMinimumSize
        }
        return result
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
    @MainActor
    final func setAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        let frame = SentFrame(topLeft: topLeft, size: size)
        if frame == sentFrame { return }
        sentFrame = frame
        sendAxFrame(topLeft, size)
    }

    /// The next ``setAxFrame(_:_:)`` sends the frame even if it's the same as the previous one
    @MainActor
    final func invalidateSentFrame() { sentFrame = nil }

    /// Use ``setAxFrame(_:_:)``
    func sendAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) { die("Not implemented") }
}

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
