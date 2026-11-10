import Common

struct WindowDetectedCallback: Withable, Equatable {
    var matcher: WindowDetectedCallbackMatcher = .command(.empty)
    var checkFurtherCallbacks: Bool = false
    var rawRun: Shell<any Command>? = nil

    var run: Shell<any Command> {
        rawRun ?? dieT("ID-46D063B2 should have discarded nil")
    }

    var debugJson: Json {
        var result: [String: Json] = [:]
        result["matcher"] = switch matcher {
            case .command(let command): .string(command.shellOfCommandsDescription)
            case .legacy(let legacy): legacy.debugJson
        }
        if let commands = rawRun {
            result["commands"] = .string(commands.shellOfCommandsDescription)
        }
        return .dict(result)
    }

    static func == (lhs: WindowDetectedCallback, rhs: WindowDetectedCallback) -> Bool {
        lhs.matcher == rhs.matcher && lhs.checkFurtherCallbacks == rhs.checkFurtherCallbacks && lhs.run.strictEquals(rhs.run)
    }
}

struct LegacyWindowDetectedCallbackMatcher: Withable, Equatable {
    var appId: String?
    var appNameRegexSubstring: CaseInsensitiveRegex?
    var windowTitleRegexSubstring: CaseInsensitiveRegex?
    var workspace: String?
    var duringAeroSpaceStartup: Bool?

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
        if let duringAeroSpaceStartup {
            resultParts.append("duringAeroSpaceStartup=\(duringAeroSpaceStartup)")
        }
        return .string(resultParts.joined(separator: ", "))
    }
}

enum WindowDetectedCallbackMatcher: Equatable {
    case command(Shell<any Command>)
    case legacy(LegacyWindowDetectedCallbackMatcher)

    static func == (lhs: WindowDetectedCallbackMatcher, rhs: WindowDetectedCallbackMatcher) -> Bool {
        switch (lhs, rhs) {
            case (.command(let command1), .command(let command2)): command1.strictEquals(command2)
            case (.legacy(let matcher1), .legacy(let matcher2)): matcher1 == matcher2
            default: false
        }
    }
}
