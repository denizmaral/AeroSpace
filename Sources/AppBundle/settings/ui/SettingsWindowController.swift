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
        if let model {
            model.reload(loadSettings().settings) // E.g. restored from the backup meanwhile
        } else {
            let model = SettingsModel(
                settings: loadSettings().settings,
                apply: { await applySettings($0) },
                onRecordingChange: { setHotkeysPaused($0) }, // They would take the keys of the shortcut that is recorded
            )
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
            self.window = window
        }
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
