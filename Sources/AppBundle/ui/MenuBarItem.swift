import AppKit
import Combine
import Common
import SwiftUI

/// The menu bar item of MarSpace and its panel: an `NSStatusItem` of its own, not SwiftUI's `MenuBarExtra`. On macOS 27
/// the menu bar shows replicas of the items: a click reaches the app only as the action of the item's button, made up
/// at the middle of the item. `MenuBarExtra` handles it inside and doesn't tell where the item was clicked, so a
/// workspace of the row couldn't be clicked (see ``MenuBarClicks``). Any other click opens the panel.
///
/// The item is drawn into an image (``MenuBarItemContent``) when what it shows changes, and once per frame while a change
/// is animated (``MenuBarAnimator``). The panel exists only while it's open
@MainActor
final class MenuBarItem: NSObject, NSWindowDelegate {
    static let shared = MenuBarItem()

    private var statusItem: NSStatusItem? = nil
    private var subscriptions: [AnyCancellable] = []
    private var appearanceObservation: NSKeyValueObservation? = nil
    private var isUpdateScheduled = false
    private var drawn: Drawn? = nil
    private var panel: MenuBarPanelWindow? = nil
    /// A click on the item closes the open panel: it loses the focus first (see ``windowDidResignKey(_:)``)
    private var panelClosedAt: ContinuousClock.Instant? = nil

    private override init() {}

    /// Before the accessibility permission is granted: the panel tells how to grant it
    func start() {
        if statusItem != nil { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = aeroSpaceAppName
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        statusItem = item
        let scheduleUpdate: (()) -> Void = { [weak self] _ in self?.scheduleUpdate() }
        subscriptions = [
            TrayMenuModel.shared.objectWillChange.sink(receiveValue: scheduleUpdate),
            MenuBarAnimator.shared.objectWillChange.sink(receiveValue: scheduleUpdate),
        ]
        appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleUpdate() }
        }
        update()
    }

    // MARK: - The item

    /// `objectWillChange` comes before the change: the item is drawn after it, once for all the changes of a session
    private func scheduleUpdate() {
        if isUpdateScheduled { return }
        isUpdateScheduled = true
        Task.startUnstructured { @MainActor in
            self.isUpdateScheduled = false
            self.update()
        }
    }

    private enum Drawn: Equatable {
        case item(MenuBarState, MenuBarTransition?, isDark: Bool)
        case symbol(String)
    }

    private func update() {
        guard let button = statusItem?.button else { return }
        let model = TrayMenuModel.shared
        let drawn: Drawn = switch (model.axPermissionStatus, model.isEnabled) {
            case (.granted, true):
                .item(model.menuBarState, MenuBarAnimator.shared.transition, isDark: button.effectiveAppearance.isDark)
            case (.granted, false): .symbol("pause.circle.fill")
            case (_, _): .symbol("exclamationmark.triangle.fill")
        }
        if drawn == self.drawn { return }
        self.drawn = drawn
        switch drawn {
            case .item(let state, let transition, let isDark):
                let content = MenuBarItemContent(state: state, transition: transition, color: isDark ? .white : .black)
                if let cgImage = content.cgImage {
                    // Drawn at twice its size in points
                    button.image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2))
                    button.title = ""
                } else {
                    button.image = nil
                    button.title = state.trayText
                }
                button.setAccessibilityLabel(state.trayText)
            case .symbol(let name):
                let image = NSImage(systemSymbolName: name, accessibilityDescription: aeroSpaceAppName)
                button.image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
                button.title = ""
                button.setAccessibilityLabel(aeroSpaceAppName)
        }
    }

    // MARK: - Clicks and the panel

    @objc private func clicked(_ button: NSStatusBarButton) {
        if let workspace = MenuBarClicks.clickedWorkspace(on: button), let token: RunSessionGuard = .isServerEnabled {
            Task.startUnstructured {
                try await runLightSession(.menuBarButton, token) { _ = Workspace.get(byName: workspace).focusWorkspace() }
            }
            return
        }
        if panel != nil {
            closePanel()
        } else if panelClosedAt.map({ .now - $0 > .milliseconds(300) }) ?? true {
            openPanel(below: button)
        }
    }

    private func openPanel(below button: NSStatusBarButton) {
        let (anchor, maxHeight) = Self.panelAnchor(below: button)
        let panel = MenuBarPanelWindow(maxHeight: maxHeight)
        panel.delegate = self
        // The window follows the size of the content (the style picker opens and closes)
        let root = MenuBarPanelWindow.content(maxHeight: maxHeight)
            .onGeometryChange(for: CGSize.self, of: \.size) { [weak self] size in self?.resizePanel(to: size) }
        let host = NSHostingView(rootView: root)
        panel.contentView = host
        self.panel = panel
        resizePanel(to: host.fittingSize, anchor: anchor)
        button.highlight(true)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func closePanel() {
        guard let panel else { return }
        self.panel = nil // Released: nothing of it is kept while it's closed
        TrayMenuModel.shared.previewMenuBarStyle(nil) // The mouse may still be over a style, it doesn't leave it
        panelClosedAt = .now
        panel.delegate = nil
        panel.orderOut(nil)
        statusItem?.button?.highlight(false)
    }

    /// The top left corner of the panel stays where it is, under the item. The content doesn't ask for more than the
    /// screen has under the item (see ``MenuBarPanel``): the window wouldn't follow it there either
    private func resizePanel(to size: CGSize, anchor: CGPoint? = nil) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let topLeft = anchor ?? CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setFrame(MenuBarPanelFrame.frame(size: size, topLeft: topLeft, maxHeight: panel.maxHeight), display: true)
        panel.invalidateShadow()
    }

    /// Under the left edge of the item, like the menus of the menu bar, and inside the screen
    /// - Returns: the top left corner of the panel, and how high it can be on the screen of the item
    private static func panelAnchor(below button: NSStatusBarButton) -> (topLeft: CGPoint, maxHeight: CGFloat) {
        guard let window = unsafe button.window, let screen = window.screen ?? NSScreen.main else {
            return (.zero, MenuBarPanelFrame.minHeight)
        }
        let width = MenuBarPanel.width
        let x = min(window.frame.minX, screen.visibleFrame.maxX - width - 6)
        let topLeft = CGPoint(x: max(screen.visibleFrame.minX + 6, x), y: window.frame.minY - 2)
        return (topLeft, MenuBarPanelFrame.maxHeight(top: topLeft.y, visibleFrame: screen.visibleFrame))
    }

    func windowDidResignKey(_ notification: Notification) {
        closePanel()
    }

    /// Escape in the panel
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closePanel()
        return false
    }
}

/// The window of the panel: no title bar, above the other windows like a menu, and it takes the keyboard (⌘Q, Escape, the
/// keys of the workspaces: see ``PanelKeyAction``)
final class MenuBarPanelWindow: NSPanel {
    /// The panels of macOS 26 are rounder. The tiles inside are concentric with it (see ``innerCornerRadius``)
    static var cornerRadius: CGFloat {
        if #available(macOS 26, *) { 24 } else { 14 }
    }
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
    /// Between the edge of the panel and its content
    static let padding: CGFloat = 14
    /// The tiles and the strip, ``padding`` in from the edge: concentric with the panel (macOS 26)
    static var innerCornerRadius: CGFloat {
        if #available(macOS 26, *) { max(6, cornerRadius - padding) } else { 10 }
    }

    /// What its screen has under the menu bar item (see ``MenuBarPanelFrame``)
    let maxHeight: CGFloat

    init(maxHeight: CGFloat) {
        self.maxHeight = maxHeight
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }

    /// What the window shows: the panel on the material of the menus, at its own size whatever the size of the window
    /// - Parameter isStylePickerShown: see ``MenuBarPanel/init(maxHeight:isStylePickerShown:isEditingStrip:)``
    @MainActor
    static func content(maxHeight: CGFloat, isStylePickerShown: Bool = false, isEditingStrip: Bool = false) -> some View {
        MenuBarPanel(maxHeight: maxHeight, isStylePickerShown: isStylePickerShown, isEditingStrip: isEditingStrip)
            .environmentObject(TrayMenuModel.shared)
            .background(PanelBackground())
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1) }
            .fixedSize()
    }

    /// The key of a workspace focuses it, with Option the workspace is kept in the menu bar or not any more. Before the
    /// views: the panel has no text to type into, and SwiftUI may keep keys that nothing handles
    override func sendEvent(_ event: NSEvent) {
        let model = TrayMenuModel.shared
        guard event.type == .keyDown, model.isEnabled, model.axPermissionStatus == .granted,
              let action = PanelKeyAction.of(event, workspaces: model.workspaces.map(\.name))
        else { return super.sendEvent(event) }
        switch action {
            case .focus(let name):
                guard let token: RunSessionGuard = .isServerEnabled else { return }
                Task.startUnstructured {
                    try await runLightSession(.menuBarButton, token) { _ = Workspace.get(byName: name).focusWorkspace() }
                }
            case .toggleFavorite(let name):
                model.toggleFavorite(name)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func performClose(_ sender: Any?) {
        if delegate?.windowShouldClose?(self) ?? true { orderOut(sender) }
    }
}

/// The material of the menus behind the panel
private struct PanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension NSAppearance {
    fileprivate var isDark: Bool { bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false }
}
