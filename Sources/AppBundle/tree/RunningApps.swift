import AppKit
import Common

/// The apps that macOS runs and what changes about them, without asking Launch Services in the refresh sessions.
///
/// A property of an `NSRunningApplication` is a round trip to Launch Services, once per instance and turn of the run loop
/// (also `processIdentifier` and `localizedName`), and `NSWorkspace.runningApplications` gives new instances every time.
/// Asking the 150 processes of a login session for their `activationPolicy` blocked the main thread for 4 to 11 ms in
/// every refresh session: more than everything else that a session does on the main thread.
///
/// An instance that is key-value observed gets its changes pushed, reading the observed properties costs nothing. So one
/// instance per app is kept and observed, and so is the list of the running apps. Nothing is polled.
@MainActor
enum RunningApps {
    private static var apps: [pid_t: RunningApp] = [:]
    private static var listObservation: NSKeyValueObservation? = nil

    /// An observed property of an app changed (its name is passed). Set when MarSpace is ready for refresh sessions
    static var onChange: (@MainActor (RunningApp, _ property: String) -> Void)? = nil

    /// The apps with a Dock icon: the apps whose windows are managed
    static var regular: [RunningApp] {
        startObserving()
        return apps.values.filter { $0.nsApp.activationPolicy == .regular && !$0.nsApp.isTerminated }
    }

    /// The app that gets the key events
    static var frontmost: RunningApp? { NSWorkspace.shared.frontmostApplication.flatMap(get) }

    static func isRunning(pid: pid_t) -> Bool {
        startObserving()
        return apps[pid].map { !$0.nsApp.isTerminated } ?? false
    }

    /// The observed instance of the app.
    ///
    /// - Parameter nsApp: any instance of the app, e.g. the one of a notification. An app that isn't known yet (its
    ///   notification came before the change of the list) is observed from now on
    /// - Returns: nil for MarSpace itself, for an app that quit, and for a process without a pid
    @discardableResult
    static func get(_ nsApp: NSRunningApplication) -> RunningApp? {
        startObserving()
        let pid = nsApp.processIdentifier
        if pid <= 0 || pid == myPid { return nil }
        // The pid of an app that quit can be reused
        if let existing = apps[pid], !existing.nsApp.isTerminated { return existing }
        if nsApp.isTerminated { return nil } // Nothing would forget it
        let app = RunningApp(nsApp, pid: pid)
        apps[pid] = app
        return app
    }

    /// Idempotent
    private static func startObserving() {
        guard listObservation == nil else { return }
        // First the observation, then the list: an app that is launched in between is in one of them
        listObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new, .old]) { _, change in
            let kind = change.kind
            let launched = kind == .insertion ? change.newValue ?? [] : []
            Task.startUnstructured { @MainActor in
                switch kind {
                    case .insertion: for nsApp in launched { get(nsApp) }
                    // Normally gone already: an app is forgotten when its `isTerminated` changes
                    case .removal: apps = apps.filter { !$0.value.nsApp.isTerminated }
                    default: sync() // The list was replaced
                }
            }
        }
        sync()
    }

    /// The apps of `running` are known, all others are forgotten
    static func sync(with running: [NSRunningApplication] = NSWorkspace.shared.runningApplications) {
        startObserving()
        var pids: Set<pid_t> = []
        for nsApp in running {
            if let app = get(nsApp) { pids.insert(app.pid) }
        }
        let running = pids
        apps = apps.filter { running.contains($0.key) && !$0.value.nsApp.isTerminated }
    }

    fileprivate static func forget(_ app: RunningApp) {
        if apps[app.pid] === app { apps[app.pid] = nil }
    }
}

/// An app that macOS runs. See ``RunningApps``
@MainActor
final class RunningApp {
    /// Key-value observed: reading `activationPolicy`, `isHidden` and `isTerminated` costs nothing, and they are up to
    /// date. Its other properties are a round trip to Launch Services: not in a refresh session
    nonisolated let nsApp: NSRunningApplication
    nonisolated let pid: pid_t
    private(set) lazy var bundleId: String? = nsApp.bundleIdentifier
    private var observations: [NSKeyValueObservation] = []

    fileprivate init(_ nsApp: NSRunningApplication, pid: pid_t) {
        self.nsApp = nsApp
        self.pid = pid
        observations = [
            observe(\.activationPolicy, "activationPolicy"),
            observe(\.isHidden, "isHidden"),
            observe(\.isTerminated, "isTerminated"),
        ]
    }

    /// The observations end before the instance is released: an NSRunningApplication that is deallocated with
    /// observations on it crashes (the instance of an app that quit, which nothing else holds anymore)
    isolated deinit {
        for observation in observations { observation.invalidate() }
    }

    private func observe(_ keyPath: KeyPath<NSRunningApplication, some Any>, _ property: String) -> NSKeyValueObservation {
        nsApp.observe(keyPath) { [weak self] _, _ in
            Task.startUnstructured { @MainActor in self?.didChange(property) }
        }
    }

    private func didChange(_ property: String) {
        if nsApp.isTerminated { RunningApps.forget(self) }
        RunningApps.onChange?(self, property)
    }
}
