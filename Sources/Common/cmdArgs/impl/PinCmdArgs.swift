public struct PinCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }

    public init(rawArgs: [String], toggle: ToggleEnum) {
        self.commonState = .init(rawArgs.slice)
        self.toggle = toggle
    }

    public static let parser: CmdParser<Self> = .init(
        kind: .pin,
        help: pin_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [ArgParser(\.toggle, parseToggleEnum)],
    )

    public var toggle: ToggleEnum = .toggle
}

func parsePinCmdArgs(_ args: StrArrSlice) -> ParsedCmd<PinCmdArgs> {
    parseSpecificCmdArgs(PinCmdArgs(rawArgs: args), args)
}
