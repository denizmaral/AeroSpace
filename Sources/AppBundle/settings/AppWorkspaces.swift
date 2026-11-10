import AppKit
import Common

/// The user moved a window to a workspace with a shortcut: the window rule of its app moves its windows there (see
/// ``Settings/assign(_:toWorkspace:)``). Not a move by a window rule, a script or the CLI
@MainActor
func assignAppWorkspace(of window: Window, _ workspace: Workspace) {
    guard case .hotkeyBinding = refreshSessionEvent, !WindowRuleContext.isRunning, let bundleId = window.app.rawAppBundleId else { return }
    SettingsStore.shared.assign(bundleId, toWorkspace: workspace.name)
}

enum WindowRuleContext {
    /// While the commands of a window rule run
    @TaskLocal static var isRunning = false
}
