import AppKit
import Common

private let testEnv = ["PATH": "AEROSPACE_TEST_PATH", "AEROSPACE_INHERITED_TEST_ENV": "inherited"]
private var env: [String: String] {
    isUnitTest ? testEnv : ProcessInfo.processInfo.environment
}

/// The environment of `exec-and-forget` (and what `list-exec-env-vars` prints): MarSpace's, with Homebrew in the PATH
var execEnvVariables: [String: String] {
    env + ["PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:\(env["PATH"] ?? "")"]
}
