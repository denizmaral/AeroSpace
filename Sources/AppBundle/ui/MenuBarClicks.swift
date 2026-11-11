import AppKit
import Common
import SwiftUI

/// A click on a workspace in the menu bar item focuses it, like the workspace buttons of a bar on Hyprland (Waybar). A
/// click anywhere else, on the focused workspace, or with a modifier key (⌘-drag rearranges the menu bar) opens the
/// panel as before.
///
/// SwiftUI's menu bar item doesn't tell where it was clicked: the clicks in MarSpace's own windows are watched (a local
/// monitor sees only those), and the one on the button of the menu bar item is mapped to the workspace under it
@MainActor
enum MenuBarClicks {
    private static var monitor: Any? = nil

    static func start() {
        if monitor != nil { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated { focusClickedWorkspace(event) } ? nil : event
        }
    }

    /// - Returns: true if the click focused a workspace: the event is consumed, the panel doesn't open
    private static func focusClickedWorkspace(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]), // Not Caps Lock
              let button = statusBarButton(at: event),
              let imageRect = button.cell?.imageRect(forBounds: button.bounds), imageRect.width > 0,
              let token: RunSessionGuard = .isServerEnabled,
              TrayMenuModel.shared.axPermissionStatus == .granted
        else { return false }
        let state = TrayMenuModel.shared.menuBarState
        let point = button.convert(event.locationInWindow, from: nil)
        guard let name = clickedWorkspace(state, atFraction: (point.x - imageRect.minX) / imageRect.width) else { return false }
        Task.startUnstructured {
            try await runLightSession(.menuBarButton, token) { _ = Workspace.get(byName: name).focusWorkspace() }
        }
        return true
    }

    /// - Parameter fraction: where the item is clicked, from its left edge (0) to its right edge (1)
    /// - Returns: nil for a click next to the workspaces, and for the focused workspace (the panel opens)
    static func clickedWorkspace(_ state: MenuBarState, atFraction fraction: CGFloat) -> String? {
        let color = Color.white // The geometry doesn't depend on it
        guard let width = MenuBarItemContent(state: state, transition: nil, color: color).cgImage.map({ CGFloat($0.width) }) else { return nil }
        let x = fraction * width
        guard let slot = MenuBarItemContent.workspaceSlots(state, color).first(where: { $0.minX <= x && x < $0.maxX }),
              state.workspaces.first(where: { $0.name == slot.name })?.isFocused == false
        else { return nil }
        return slot.name
    }

    private static func statusBarButton(at event: NSEvent) -> NSStatusBarButton? {
        var view = event.window?.contentView?.hitTest(event.locationInWindow)
        while let current = view, !(current is NSStatusBarButton) { view = unsafe current.superview } // unowned(unsafe) in AppKit
        return view as? NSStatusBarButton
    }
}
