import Common

func parseCommand(
    _ raw: String,
    allowExecAndForget: Bool,
    allowEval: Bool,
) -> ParsedCmd<Shell<any Command>> {
    if allowExecAndForget && raw.starts(with: "exec-and-forget") {
        return .cmd(.cmd(ExecAndForgetCommand(args: ExecAndForgetCmdArgs(bashScript: raw.removePrefix("exec-and-forget")))))
    }
    return switch raw.lexAndParseShell() {
        case .success(let it):
            it.flatMap { args in
                switch parseCommand(args) {
                    case .cmd(_ as EvalCommand) where !allowEval: .failure("Illegal eval (Tip: nested evals are forbidden)", EXIT_CODE_TWO)
                    case .cmd(let it): .cmd(it)
                    case .failure(let it): .failure(it)
                    case .help(let it): .help(it)
                }
            }
        case .failure(let it): ParsedCmd.failure(it, EXIT_CODE_TWO)
    }
}

func parseCommand(_ args: [String]) -> ParsedCmd<any Command> {
    parseCmdArgs(args.slice).flatMap { $0.toCommand() }
}
