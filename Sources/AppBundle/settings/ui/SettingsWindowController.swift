import AppKit
import Common
import SwiftUI

/// The settings window. MarSpace has a Dock icon while it's open (it can be found with cmd-tab), none otherwise
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow? = nil
    private var model: SettingsModel? = nil

    func show() {
        if model == nil {
            // The settings are those of the store: nothing to load, nothing that the window keeps on its own
            let model = SettingsModel(store: .shared, onRecordingChange: { setHotkeysPaused($0) }) // They'd take the keys
            self.model = model
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "\(aeroSpaceAppName) Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 920, height: 660))
            window.center()
            window.setFrameAutosaveName("MarSpaceSettings")
            model.store.undoManager = window.undoManager // ⌘Z, ⇧⌘Z and the Edit menu
            self.window = window
        }
        // The Dock keeps the tile image of a bundle id: AeroSpace's (the same id) would come back. The icon of the bundle
        // goes to the Dock tile directly
        NSApp.applicationIconImage = Bundle.main.image(forResource: "AppIcon")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// The key labels follow the keyboard layout of macOS
    func keyboardLayoutChanged() {
        model?.keyboardLayoutChanges &+= 1
    }

    func windowWillClose(_ notification: Notification) {
        model?.isRecordingShortcut = false
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Opening MarSpace again while it runs (Finder, Spotlight, `open -a MarSpace`) shows the settings window, like other menu
/// bar apps do
public final class MarSpaceAppDelegate: NSObject, NSApplicationDelegate {
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }
}
