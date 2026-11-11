import AppKit
import Common
import Foundation

@MainActor public func initAppBundle() {
    Task.startUnstructured {
        initTerminationHandler()
        unsafe _isCli = false
        unsafe _isUnitTest = false
        initServerArgs()
        await waitForAccessibilityPermission_nonCancellable()
        if isDebug {
            await toggleReleaseServerIfDebug(.off)
            interceptTermination(SIGINT)
        }

        _ = await reloadConfig_nonCancellable()
        startObservingKeyboardLayout()

        startUnixSocketServer()
        GlobalObserver.initObserver()
        MissionControl.observe()
        Workspace.garbageCollectUnusedWorkspaces() // init workspaces
        for monitor in Monitor.all {
            _ = monitor.getWorkspacesContainerOrCreate().children.filterIsInstance(of: Workspace.self)
                .min()?
                .focusWorkspace()
        }
        await runHeavyCompleteRefreshSession(
            .startup,
            // It's important for the first initialization to be non cancellable
            // to make sure that isStartup propagates to all places
            assumeCancellable: false,
            layoutWorkspaces: false,
        )
        try await runLightSession(.startup, .forceRun) {
            _ = await config.afterStartupCommand.run(.defaultEnv, .emptyStdin)
        }
    }
}

var isStartup: Bool { refreshSessionEvent?.isStartup == true }

struct ServerArgs: Sendable {
    var isReadOnly: Bool = false
}

private let serverHelp = """
    USAGE: \(CommandLine.arguments.first ?? "MarSpace.app/Contents/MacOS/MarSpace") [<options>]

    OPTIONS:
      -h, --help              Print help
      -v, --version           Print the version of MarSpace

      --read-only             Disable window management.
                              Useful if you want to use only debug-windows or other query commands.
    """

nonisolated(unsafe) private var _serverArgs = ServerArgs()
var serverArgs: ServerArgs { unsafe _serverArgs }
private func initServerArgs() {
    let args = CommandLine.arguments.slice(1...) ?? []
    if args.contains(where: { $0 == "-h" || $0 == "--help" }) {
        exit(EXIT_CODE_ZERO, out: serverHelp)
    }
    var index = 0
    while index < args.count {
        let current = args[index]
        index += 1
        switch current {
            case "--version", "-v":
                exit(EXIT_CODE_ZERO, out: "\(aeroSpaceAppVersion) \(gitHash)")
            case "--read-only": // todo rename to '--disabled' and unite with disabled feature
                unsafe _serverArgs.isReadOnly = true
            case "-NSDocumentRevisionsDebugMode" where isDebug:
                // Skip Xcode CLI args.
                // Usually it's '-NSDocumentRevisionsDebugMode NO'/'-NSDocumentRevisionsDebugMode YES'
                while args.getOrNil(atIndex: index)?.starts(with: "-") == false { index += 1 }
            default:
                exit(EXIT_CODE_TWO, err: "Unrecognized flag \(args.first.orDie().singleQuoted)")
        }
    }
}
