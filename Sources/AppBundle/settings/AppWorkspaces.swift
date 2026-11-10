import AppKit
import Common

/// An app opens on the workspace where the user put it (``Settings/appWorkspaces``): its first windows when it's launched,
/// and its windows without a placement of a previous run at the startup of MarSpace (e.g. after a restart of the Mac).
/// Later windows open on the focused workspace, like those of other apps. A window rule runs after and wins
@MainActor
func appWorkspace(forNewWindowOf bundleId: String?, appIsStarting: Bool, isStartup: Bool) -> String? {
    guard let bundleId, appIsStarting || isStartup else { return nil }
    return config.appWorkspaces[bundleId]
}

/// The user moved a window to a workspace: its app opens there the next time. Only a move by a shortcut counts, not one by
/// a window rule, a script or the CLI
@MainActor
func rememberAppWorkspace(of window: Window, _ workspace: Workspace) {
    guard case .hotkeyBinding = refreshSessionEvent, !WindowRuleContext.isRunning, let bundleId = window.app.rawAppBundleId else { return }
    SettingsStore.shared.remember(bundleId, onWorkspace: workspace.name)
}

enum WindowRuleContext {
    /// While the commands of a window rule run
    @TaskLocal static var isRunning = false
}
