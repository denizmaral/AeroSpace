import AppKit
import Common
import SwiftUI

/// A click on a workspace in the menu bar item focuses it, like the workspace buttons of a bar on Hyprland (Waybar). A
/// click anywhere else, on the focused workspace, with the right button or with a modifier key opens the panel
/// (see ``MenuBarItem``)
@MainActor
enum MenuBarClicks {
    /// - Returns: the workspace that the item was clicked on. nil: the panel opens
    static func clickedWorkspace(on button: NSStatusBarButton) -> String? {
        let model = TrayMenuModel.shared
        guard model.experimentalUISettings.switchesWorkspaceOnClick,
              NSApp.currentEvent?.type == .leftMouseDown,
              NSEvent.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]), // Not Caps Lock
              model.isEnabled, model.axPermissionStatus == .granted,
              let window = unsafe button.window, let content = window.contentView,
              let imageRect = button.cell?.imageRect(forBounds: button.bounds), imageRect.width > 0
        else { return nil }
        // The event is made up by macOS at the middle of the item: the mouse tells where it was clicked. Anywhere in the
        // height of the menu bar (the mouse is thrown to the top edge of the screen), not only on the button. Elsewhere
        // (pressed with VoiceOver, the menu bar of another display): the panel
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard content.frame.contains(inWindow) else { return nil }
        let point = button.convert(inWindow, from: nil)
        guard point.x >= imageRect.minX, point.x < imageRect.maxX else { return nil }
        // The button is flipped (verified on macOS 27). Above or below the image (the top edge of the screen): its row
        let y = (point.y - imageRect.minY) / imageRect.height
        let fromTop = min(max(button.isFlipped ? y : 1 - y, 0), 0.999)
        return clickedWorkspace(model.menuBarState, atFraction: (point.x - imageRect.minX) / imageRect.width, fromTop: fromTop)
    }

    /// - Parameters:
    ///   - fraction: where the item is clicked, from its left edge (0) to its right edge (1)
    ///   - fromTop: from its top edge (0) to its bottom edge (1)
    /// - Returns: nil for a click next to the workspaces, and for the focused workspace (the panel opens)
    static func clickedWorkspace(_ state: MenuBarState, atFraction fraction: CGFloat, fromTop: CGFloat = 0.5) -> String? {
        let color = Color.white // The geometry doesn't depend on it
        guard let image = MenuBarItemContent(state: state, transition: nil, color: color).cgImage else { return nil }
        let (x, y) = (fraction * CGFloat(image.width), fromTop * CGFloat(image.height))
        guard let slot = MenuBarItemContent.workspaceSlots(state, color).first(where: { $0.minX <= x && x < $0.maxX && $0.minY <= y && y < $0.maxY }),
              state.workspaces.first(where: { $0.name == slot.name })?.isFocused == false
        else { return nil }
        return slot.name
    }
}
