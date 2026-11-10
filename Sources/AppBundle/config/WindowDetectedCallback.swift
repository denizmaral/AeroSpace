import Common

/// A window rule of the settings, for the engine: the windows that it matches, and the commands that run for them
struct WindowDetectedCallback: Withable, Equatable {
    var matcher = WindowMatcher()
    var checkFurtherCallbacks: Bool = false
    var run: Shell<any Command>

    var debugJson: Json {
        .dict(["matcher": matcher.debugJson, "commands": .string(run.shellOfCommandsDescription)])
    }

    static func == (lhs: WindowDetectedCallback, rhs: WindowDetectedCallback) -> Bool {
        lhs.matcher == rhs.matcher && lhs.checkFurtherCallbacks == rhs.checkFurtherCallbacks && lhs.run.strictEquals(rhs.run)
    }
}

/// Every condition that is set must hold. Without conditions: every window
struct WindowMatcher: Withable, Equatable {
    var appId: String?
    var appNameRegexSubstring: CaseInsensitiveRegex?
    var windowTitleRegexSubstring: CaseInsensitiveRegex?
    var workspace: String?
    var duringStartup: Bool?

    @MainActor
    func matches(_ window: Window) async -> Bool {
        if let duringStartup, duringStartup != isStartup {
            return false
        }
        if let windowTitleRegexSubstring, (try? await window.getTitle(.nonCancellable))?.contains(caseInsensitiveRegex: windowTitleRegexSubstring) != true {
            return false
        }
        if let appId, appId != window.app.rawAppBundleId {
            return false
        }
        if let appNameRegexSubstring, !(window.app.name ?? "").contains(caseInsensitiveRegex: appNameRegexSubstring) {
            return false
        }
        if let workspace, workspace != window.nodeWorkspace?.name {
            return false
        }
        return true
    }

    var debugJson: Json {
        var resultParts: [String] = []
        if let appId {
            resultParts.append("appId=\"\(appId)\"")
        }
        if let appNameRegexSubstring {
            resultParts.append("appNameRegexSubstring=\"\(appNameRegexSubstring.origin)\"")
        }
        if let windowTitleRegexSubstring {
            resultParts.append("windowTitleRegexSubstring=\"\(windowTitleRegexSubstring.origin)\"")
        }
        if let workspace {
            resultParts.append("workspace=\"\(workspace)\"")
        }
        if let duringStartup {
            resultParts.append("duringStartup=\(duringStartup)")
        }
        return .string(resultParts.joined(separator: ", "))
    }
}
