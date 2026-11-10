import AppKit
import Common

/// Draws `[focus-border]` around the focused window.
///
/// The border is drawn by a click-through panel that is `width` points bigger than the window on every side, so the
/// border lives in the gap around the window. Even when the app raises its window above the panel, the border stays
/// visible. The panel is updated at the end of every refresh session; there is no polling.
@MainActor
final class FocusBorderController {
    static let shared = FocusBorderController()

    private var panel: FocusBorderPanel? = nil
    private var drawnAppearance: Appearance? = nil
    private var orderedAboveNativeWindowId: UInt32? = nil
    /// A window is moved or resized with the mouse. The border is updated at the end of refresh sessions, it can't follow
    /// the window frame by frame: it's hidden until the mouse button is released
    private var isHiddenForMouseDrag = false

    // periphery:ignore - the properties are only compared (Equatable)
    private struct Appearance: Equatable {
        let size: CGSize
        let border: FocusBorder
    }

    private init() {}

    func update() async {
        if isUnitTest { return }
        if isHiddenForMouseDrag && !isLeftMouseButtonDown {
            isHiddenForMouseDrag = false // The mouse up event was missed
        }
        let border = config.focusBorder
        guard border.enabled,
              !isHiddenForMouseDrag,
              TrayMenuModel.shared.isEnabled,
              !MissionControl.isActive,
              let window = globalFocus.windowOrNil as? MacWindow,
              let nativeWindowId = window.macApp.nativeWindowId(of: window.windowId),
              isOnActiveSpace(nativeWindowId)
        else { return hide() }

        let windowRect: Rect?
        do {
            windowRect = try await window.focusBorderRect()
        } catch {
            return // The session was canceled. The next session updates the border
        }
        guard let windowRect, windowRect.width > 0, windowRect.height > 0 else { return hide() }

        let frame = focusBorderPanelFrame(windowRect: windowRect, borderWidth: border.width, mainMonitorHeight: mainMonitorInfo.height)
        let panel = getOrCreatePanel()
        let appearance = Appearance(size: frame.size, border: border)
        if drawnAppearance != appearance {
            panel.draw(size: frame.size, border)
            drawnAppearance = appearance
        }
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
        }
        // Window server round trip. The border is outside of the window, so it stays visible even if the app raises
        // its window above the panel. Reorder only when the focused window changes
        if !panel.isVisible || orderedAboveNativeWindowId != nativeWindowId {
            panel.order(.above, relativeTo: Int(nativeWindowId))
            orderedAboveNativeWindowId = nativeWindowId
        }
    }

    private var spaceChangeRecheck: Task<(), any Error>? = nil

    /// macOS posts the Space change before its animation ends: the refresh session right after it still sees the windows
    /// of the previous Space on screen and draws their border, and the panel follows into the new Space (e.g. the Space
    /// of a native fullscreen window). Check again when the animation is over
    func hideAfterSpaceChange() {
        hide()
        spaceChangeRecheck?.cancel()
        spaceChangeRecheck = Task.startUnstructured { @MainActor in
            for delay in [700, 800] { // ms: after the animation, and once more for slow transitions
                try await Task.sleep(for: .milliseconds(delay))
                await self.update() // The singleton
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
        orderedAboveNativeWindowId = nil
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

/// The windows of other macOS Spaces aren't on screen, e.g. the windows of the desktop while a native fullscreen window
/// has its own Space: AeroSpace may focus one of them, and the panel (it moves to the active Space) drew its border over
/// the fullscreen window. A window server query, no accessibility calls
private func isOnActiveSpace(_ nativeWindowId: UInt32) -> Bool {
    guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(nativeWindowId)) as? [[String: Any]])?.first else {
        return true // Unknown
    }
    // The key is present only for windows that are on screen
    return info[kCGWindowIsOnscreen as String] as? Bool ?? false
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

extension MacWindow {
    /// The rect that the focus border surrounds, or nil if the border must be hidden
    @MainActor
    fileprivate func focusBorderRect() async throws -> Rect? {
        guard nodeWorkspace?.isVisible == true else { return nil }
        return switch windowParentCases {
            case .tilingContainer: isFullscreen ? try await getAxRect(.cancellable) : lastAppliedLayoutPhysicalRect
            case .floatingWindowsContainer: try await getAxRect(.cancellable)
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
