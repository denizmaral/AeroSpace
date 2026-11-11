public struct TileFloatingWindowsCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .tileFloatingWindows,
        help: tile_floating_windows_help_generated,
        flags: [
            "--workspace": workspaceSubArgParser(),
        ],
        posArgs: [],
    )
}
