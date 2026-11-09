import AppKit
import Common

protocol Command: AeroAny, Equatable, Sendable {
    associatedtype T: CmdArgs

    var args: T { get }
    @MainActor
    func run(_ env: CmdEnv, _ io: CmdIo) async -> T.ExitCodeType

    /// We should reset closedWindowsCache when the command can potentially change the tree
    var shouldResetClosedWindowsCache: Bool { get }

    /// The command only reads the model (it doesn't change the tree, the focus, windows or the config).
    /// Read-only commands skip layout and the follow-up refresh session. See ``runLightSession(_:_:readOnly:body:)``
    var isReadOnly: Bool { get }
}

extension Command {
    var isReadOnly: Bool { false }
}

extension Command {
    static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.args.equals(rhs.args)
    }

    nonisolated func equals(_ other: any Command) -> Bool {
        (other as? Self).flatMap { self == $0 } ?? false
    }
}

extension Command {
    var info: CmdStaticInfo { T.info }
}

extension Command {
    @MainActor
    @discardableResult
    func run(_ env: CmdEnv, _ stdin: consuming CmdStdin) async -> CmdResult {
        return await Shell.cmd(self).run(env, stdin)
    }
}
