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
            model.settings = loadSettings().settings // E.g. restored from the backup meanwhile. Unchanged settings aren't applied
        } else {
            let model = SettingsModel(
                settings: loadSettings().settings,
                apply: { await applySettings($0) },
                onRecordingChange: { isRecording in
                    // MarSpace's shortcuts would take the keys of the shortcut that is being recorded
                    if isRecording {
                        resetHotKeys()
                    } else {
                        Task.startUnstructured { await activateMode_nonCancellable(activeMode) }
                    }
                },
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

    func windowWillClose(_ notification: Notification) {
        model?.isRecordingShortcut = false
        NSApp.setActivationPolicy(.accessory)
    }
}
