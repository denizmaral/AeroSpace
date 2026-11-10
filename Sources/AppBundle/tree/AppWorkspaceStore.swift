import AppKit
import Common

/// The workspace that each app was last moved to by the user (`move-node-to-workspace`, `move-node-to-monitor`, the
/// shortcuts of the workspaces). When the app is launched again, its first window opens there: an app put on a workspace
/// stays there, also after it was quit or the Mac was restarted. Window rules run after and win.
///
/// Only explicit moves count: an app isn't tied to the workspace where it merely happened to be opened. Kept in
/// `~/Library/Application Support/MarSpace/AppWorkspaces.plist` (bundle id → workspace name)
@MainActor
enum AppWorkspaceStore {
    private static var url: URL { SettingsRepository.applicationSupport.directory.appending(path: "AppWorkspaces.plist") }
    private static var workspaces: [String: String] = isUnitTest ? [:] : load()

    static func remember(_ bundleId: String?, _ workspace: String) {
        guard let bundleId, workspaces[bundleId] != workspace else { return }
        workspaces[bundleId] = workspace
        if !isUnitTest { save() }
    }

    /// The workspace of a new window of the app while the app is starting (it was launched, or all its windows were
    /// closed), or of any of its windows while MarSpace starts (e.g. after a restart of the Mac, the windows have no
    /// placement of a previous run). Later windows open on the focused workspace, like the windows of other apps
    static func workspace(forNewWindowOf bundleId: String?, appIsStarting: Bool, isStartup: Bool) -> String? {
        guard let bundleId, appIsStarting || isStartup else { return nil }
        return workspaces[bundleId]
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let workspaces = try? PropertyListDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return workspaces
    }

    private static func save() {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(workspaces).write(to: url, options: .atomic)
        } catch {
            perfLogger.error("Can't save the workspaces of the apps: \(error.localizedDescription, privacy: .public)")
        }
    }
}
