import AppKit
import Common

/// Draws `[focus-border]` around the focused window.
///
/// The border is drawn by a click-through panel that is `width` points bigger than the window on every side, so the
/// border lives in the gap around the window. Even when the app raises its window above the panel, the border stays
/// visible.
///
/// The panel follows the observed frame of the window (``Window/observedFrame``, what the user sees, not the tile) and is
/// updated synchronously: at the end of every refresh session, and when the frame of the focused window is read back
/// after a session. There is no polling.
@MainActor
final class FocusBorderController {
    static let shared = FocusBorderController()

    private var panel: FocusBorderPanel? = nil
    private var drawnAppearance: Appearance? = nil
    /// A window is moved or resized with the mouse. The border is updated at the end of refresh sessions, it can't follow
    /// the window frame by frame: it's hidden until the mouse button is released
    private var isHiddenForMouseDrag = false
    /// See ``update()``
    private var stackingRecheck: Task<(), any Error>? = nil

    // periphery:ignore - the properties are only compared (Equatable)
    private struct Appearance: Equatable {
        let size: CGSize
        let border: FocusBorder
    }

    private init() {}

    func update() { update(isStackingRecheck: false) }

    private func update(isStackingRecheck: Bool) {
        if isUnitTest { return }
        if isHiddenForMouseDrag && !isLeftMouseButtonDown {
            isHiddenForMouseDrag = false // The mouse up event was missed
        }
        let border = config.focusBorder
        guard border.enabled,
              !isHiddenForMouseDrag,
              !isHiddenForSpaceChange,
              TrayMenuModel.shared.isEnabled,
              !MissionControl.isActive,
              let window = globalFocus.windowOrNil as? MacWindow,
              let nativeWindowId = window.macApp.nativeWindowId(of: window.windowId),
              let windowRect = window.focusBorderRect
                  .map({ focusBorderWindowRect($0, monitor: window.nodeMonitorInfo?.rect, borderWidth: border.width) }),
              windowRect.width > 0, windowRect.height > 0
        else { return hide() }
        let panel = getOrCreatePanel()
        let stacking = windowStacking(of: nativeWindowId, pid: window.macApp.pid, panel: panel.isVisible ? CGWindowID(panel.windowNumber) : nil)
        if stacking == .offScreen { return hide() }

        let frame = focusBorderPanelFrame(windowRect: windowRect, borderWidth: border.width, mainMonitorHeight: mainMonitorInfo.height)
        let appearance = Appearance(size: frame.size, border: border)
        if drawnAppearance != appearance {
            panel.draw(size: frame.size, border)
            drawnAppearance = appearance
        }
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
        }
        // The panel must be right above the window. The border is outside of the window, so it stays visible if the app
        // raises its window above the panel, but not if the window server raises the window of a newly activated app
        // above the panel AND above its neighbors (it does it asynchronously): they cover the border where they overlap
        // the window. Checked once more a moment later, the raise may still be under way
        if stacking != .onScreen(isPanelRightAbove: true) {
            panel.order(.above, relativeTo: Int(nativeWindowId))
            if !isStackingRecheck {
                stackingRecheck?.cancel()
                stackingRecheck = Task.startUnstructured { @MainActor in
                    try await Task.sleep(for: .milliseconds(250))
                    self.update(isStackingRecheck: true) // The singleton
                }
            }
        }
    }

    /// The observed frame of a window changed, e.g. it was read back after a session (a refresh session updates the
    /// border at its end anyway)
    func windowFrameDidChange(_ window: Window) {
        if refreshSessionEvent == nil, window == globalFocus.windowOrNil { update() }
    }

    private var spaceChangeRecheck: Task<(), any Error>? = nil
    /// See ``hideAfterSpaceChange()``
    private var isHiddenForSpaceChange = false

    /// macOS posts the Space change before its animation ends: the refresh session right after it still sees the windows
    /// of the previous Space on screen and drew their border, and the panel followed into the new Space (e.g. the Space
    /// of a native fullscreen window). The border stays hidden during the animation and is checked when it's over
    func hideAfterSpaceChange() {
        isHiddenForSpaceChange = true
        hide()
        spaceChangeRecheck?.cancel()
        spaceChangeRecheck = Task.startUnstructured { @MainActor in
            for delay in [700, 800] { // ms: after the animation, and once more for slow transitions
                try await Task.sleep(for: .milliseconds(delay))
                self.isHiddenForSpaceChange = false // The singleton
                self.update()
            }
        }
    }

    /// See ``isHiddenForMouseDrag``
    func hideForMouseDrag() {
        isHiddenForMouseDrag = true
        hide()
    }

    /// The refresh session after the mouse up event draws the border again
    func showAfterMouseDrag() {
        isHiddenForMouseDrag = false
    }

    func hide() {
        stackingRecheck?.cancel()
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func getOrCreatePanel() -> FocusBorderPanel {
        if let panel { return panel }
        let panel = FocusBorderPanel()
        self.panel = panel
        return panel
    }
}

/// Where the focused window is in the stacking of the window server. One query, no accessibility calls
private enum WindowStacking: Equatable {
    /// Not on the active macOS Space, e.g. a window of the desktop while a native fullscreen window has its own Space:
    /// AeroSpace may focus one of them, and the panel (it moves to the active Space) drew its border over the fullscreen
    /// window
    case offScreen
    /// - Parameter isPanelRightAbove: the panel is above the window, and no window of another app is between them (an app
    ///   may keep its own helper window right above its window)
    case onScreen(isPanelRightAbove: Bool)
    /// The query failed
    case unknown
}

private func windowStacking(of nativeWindowId: UInt32, pid: pid_t, panel: CGWindowID?) -> WindowStacking {
    let infos = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .optionIncludingWindow], CGWindowID(nativeWindowId))
        as? [[String: Any]] ?? []
    guard let own = infos.last else { return .unknown }
    // Front to back: the windows in front of the window, then the window itself. A window of another Space isn't listed
    guard (own[kCGWindowNumber as String] as? Int) == Int(nativeWindowId) else { return .offScreen }
    for info in infos.dropLast().reversed() where (info[kCGWindowLayer as String] as? Int) == 0 { // From the window up
        if let panel, (info[kCGWindowNumber as String] as? Int) == Int(panel) { return .onScreen(isPanelRightAbove: true) }
        if (info[kCGWindowOwnerPID as String] as? Int32) != pid { return .onScreen(isPanelRightAbove: false) }
    }
    return .onScreen(isPanelRightAbove: false)
}

/// Frame of the border panel in Cocoa coordinates (the origin is at the bottom left corner of the main monitor).
/// `windowRect` is in AeroSpace coordinates (the origin is at the top left corner of the main monitor)
func focusBorderPanelFrame(windowRect: Rect, borderWidth: Int, mainMonitorHeight: CGFloat) -> CGRect {
    let width = CGFloat(borderWidth)
    return CGRect(
        x: windowRect.topLeftX,
        y: mainMonitorHeight - windowRect.topLeftY - windowRect.height,
        width: windowRect.width,
        height: windowRect.height,
    ).insetBy(dx: -width, dy: -width)
}

/// The rect that the border surrounds. A window that refuses to shrink to its tile can reach beyond the monitor (it's
/// placed at the tile, App Store is at least 1000 wide): on that side the border follows the monitor edge, otherwise it's
/// off screen
func focusBorderWindowRect(_ window: Rect, monitor: Rect?, borderWidth: Int) -> Rect {
    guard let monitor else { return window }
    let width = CGFloat(borderWidth)
    let minX = window.minX < monitor.minX ? monitor.minX + width : window.minX
    let maxX = window.maxX > monitor.maxX ? monitor.maxX - width : window.maxX
    let minY = window.minY < monitor.minY ? monitor.minY + width : window.minY
    let maxY = window.maxY > monitor.maxY ? monitor.maxY - width : window.maxY
    return Rect(topLeftX: minX, topLeftY: minY, width: maxX - minX, height: maxY - minY)
}

extension MacWindow {
    /// The frame of the window that the focus border surrounds, or nil if the border must be hidden
    @MainActor
    fileprivate var focusBorderRect: Rect? {
        guard nodeWorkspace?.isVisible == true else { return nil }
        return switch windowParentCases {
            // Not the tile: the window can be bigger than its tile
            case .tilingContainer: observedFrame ?? lastAppliedLayoutPhysicalRect
            case .floatingWindowsContainer: observedFrame
            case .macosFullscreenWindowsContainer, .macosMinimizedWindowsContainer, .macosHiddenAppsWindowsContainer,
                 .macosPopupWindowsContainer, nil: nil
        }
    }
}

private final class FocusBorderPanel: NSPanel {
    private let gradientLayer = CAGradientLayer()
    private let strokeMask = CAShapeLayer()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        level = .normal
        // Belong to a single Space at a time (otherwise it flashes on other Spaces, e.g. native fullscreen Spaces),
        // move to the active Space when ordered in, don't participate in cmd-` window cycling
        collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]

        let view = NSView()
        view.wantsLayer = true
        contentView = view
        strokeMask.fillColor = nil
        strokeMask.strokeColor = CGColor(gray: 0, alpha: 1)
        gradientLayer.mask = strokeMask
        view.layer?.addSublayer(gradientLayer)
    }

    func draw(size: CGSize, _ border: FocusBorder) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let bounds = CGRect(origin: .zero, size: size)
        let lineWidth = CGFloat(border.width)
        let strokeRect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let radius = min(CGFloat(border.radius) + lineWidth / 2, strokeRect.width / 2, strokeRect.height / 2)
        let scale = screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        gradientLayer.frame = bounds
        gradientLayer.contentsScale = scale
        strokeMask.frame = bounds
        strokeMask.contentsScale = scale
        strokeMask.lineWidth = lineWidth
        strokeMask.path = unsafe CGPath(roundedRect: strokeRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        switch border.color {
            case .solid(let color):
                gradientLayer.colors = [color.argbCgColor, color.argbCgColor]
            case .gradient(let start, let end, let fromTopLeft):
                gradientLayer.colors = [start.argbCgColor, end.argbCgColor]
                // Layer coordinates: the origin is at the bottom left corner
                gradientLayer.startPoint = fromTopLeft ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 1)
                gradientLayer.endPoint = fromTopLeft ? CGPoint(x: 1, y: 0) : CGPoint(x: 0, y: 0)
        }
    }
}
