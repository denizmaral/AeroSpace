import AppKit
import Common
import SwiftUI

/// The settings window. MarSpace has a Dock icon while it's open (it can be found with cmd-tab), none otherwise.
///
/// The window and its views exist only while it's open: MarSpace runs all day, the settings are opened once in a while
/// (the views of the window are most of the memory of MarSpace)
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private(set) var window: NSWindow? = nil
    private(set) var model: SettingsModel? = nil

    func show() {
        let window = window ?? makeWindow()
        // The Dock keeps the tile image of a bundle id: AeroSpace's (the same id) would come back. The icon of the bundle
        // goes to the Dock tile directly
        NSApp.applicationIconImage = Bundle.main.image(forResource: "AppIcon")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    @discardableResult
    func makeWindow() -> NSWindow {
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
        return window
    }

    /// The key labels follow the keyboard layout of macOS
    func keyboardLayoutChanged() {
        model?.keyboardLayoutChanges &+= 1
    }

    func windowWillClose(_ notification: Notification) {
        model?.isRecordingShortcut = false
        NSApp.setActivationPolicy(.accessory)
        // Not in the middle of its closing
        Task.startUnstructured { @MainActor in self.releaseWindowIfClosed() } // The singleton
    }

    private func releaseWindowIfClosed() {
        guard let window, !window.isVisible else { return } // Opened again meanwhile
        window.delegate = nil
        window.contentViewController = nil
        self.window = nil
        model = nil
    }
}

/// Opening MarSpace again while it runs (Finder, Spotlight, `open -a MarSpace`) shows the settings window, like other menu
/// bar apps do
public final class MarSpaceAppDelegate: NSObject, NSApplicationDelegate {
    /// Before the accessibility permission is granted: the panel of the item tells how to grant it
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // MarSpace has no window most of the time: the menu bar item is an NSStatusItem, and the only SwiftUI scene (the
        // message window) isn't open. macOS would end an app without windows a few seconds after it started
        ProcessInfo.processInfo.disableAutomaticTermination("MarSpace manages the windows")
        MenuBarItem.shared.start()
    }

    /// SwiftUI ends an app whose only scene is a window when no window is open, also right after the launch
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }

    /// Every way to quit (⌘Q and the Dock while the settings window is open, logging out, `kill`) puts the windows back on
    /// screen, not only "Quit" in the menu: the windows of the workspaces that aren't shown would stay in the corner
    public func applicationWillTerminate(_ notification: Notification) {
        runTerminationHandlerOnce()
    }
}
