import AppKit
import Common

let testEnv = ["PATH": "AEROSPACE_TEST_PATH", "AEROSPACE_INHERITED_TEST_ENV": "inherited"]
private var env: [String: String] {
    isUnitTest ? testEnv : ProcessInfo.processInfo.environment
}

let defaultOverriddenEnvVars = ["PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:\(env["PATH"] ?? "")"]

struct ExecConfig: Equatable {
    var envVariables: [String: String] = env + defaultOverriddenEnvVars
}
