public struct WorkspaceLayoutCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .workspaceLayout,
        help: workspace_layout_help_generated,
        flags: [
            "--workspace": workspaceSubArgParser(),
            "--fail-if-noop": trueBoolFlag(\.failIfNoop),
        ],
        posArgs: [newMandatoryPosArgParser(\.cycle, parseCycle, placeholder: WorkspaceLayout.unionLiteral)],
    )

    /// The layouts to cycle through: the workspace takes the one after its layout, the first one if its layout isn't
    /// among them
    public var cycle: Lateinit<[WorkspaceLayout]> = .uninitialized
    public var failIfNoop: Bool = false

    public init(rawArgs: [String], cycle: [WorkspaceLayout]) {
        self.commonState = .init(rawArgs.slice)
        self.cycle = .initialized(cycle)
    }
}



private func parseCycle(input: PosArgParserInput) -> ParsedCliArgs<[WorkspaceLayout]> {
    let args = input.nonFlagArgs()
    var result: [WorkspaceLayout] = []
    for (i, arg) in args.enumerated() {
        guard let layout = WorkspaceLayout(rawValue: arg) else {
            return .fail("Can't parse '\(arg)'\nPossible values: \(WorkspaceLayout.unionLiteral)", advanceBy: i + 1)
        }
        result.append(layout)
    }
    return .succ(result, advanceBy: args.count)
}

func parseWorkspaceLayoutCmdArgs(_ args: StrArrSlice) -> ParsedCmd<WorkspaceLayoutCmdArgs> {
    parseSpecificCmdArgs(WorkspaceLayoutCmdArgs(rawArgs: args), args)
        .filter("--fail-if-noop allows only one <layout> argument") { $0.failIfNoop.implies($0.cycle.val.count == 1) }
}
