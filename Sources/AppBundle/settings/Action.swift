import Common

/// What a shortcut, a window rule or an automation does. The settings window edits the typed cases with pickers;
/// ``custom(_:)`` is the escape hatch for any other command line (validated by the command parser).
///
/// A typed action builds its engine command from its values (``command``), without the parser: the same commands as the
/// CLI, nothing is implemented twice
enum Action: Codable, Sendable, Equatable {
    case focus(CardinalDirection)
    case move(CardinalDirection)
    case joinWith(CardinalDirection)
    case resize(ResizeCmdArgs.Dimension, ResizeAmount)
    case workspace(String)
    case workspaceBackAndForth
    case moveWindowToWorkspace(String)
    case moveWorkspaceToMonitor(MonitorStep, wrapAround: Bool)
    /// Cycles through the layouts: e.g. tiles and accordion, horizontal and vertical, floating and tiling
    case layout([LayoutOption])
    /// Toggles the fullscreen
    case fullscreen(FullscreenKind)
    /// Nothing if the window is already fullscreen: e.g. a window rule for a window that is detected again
    case enterFullscreen(FullscreenKind)
    case exitFullscreen(FullscreenKind)
    case flattenWorkspaceTree
    case balanceSizes
    case closeWindow
    case closeAllWindowsButCurrent
    case enterMode(String)
    case reloadSettings
    case moveMouse(MouseTarget)
    /// Any command line, e.g. `exec-and-forget open -a Terminal`
    case custom(String)

    enum ResizeAmount: Codable, Sendable, Equatable {
        case add(UInt)
        case subtract(UInt)
        case set(UInt)
    }

    enum MonitorStep: String, Codable, Sendable, CaseIterable {
        case next, prev
    }

    enum LayoutOption: String, Codable, Sendable, CaseIterable {
        case tiles, accordion, horizontal, vertical, floating, tiling
    }

    enum FullscreenKind: String, Codable, Sendable, CaseIterable {
        /// The window fills its workspace, the others stay tiled behind it
        case marSpace
        /// The window gets its own macOS Space (the green window button)
        case macOSNative

        var command: String { self == .marSpace ? "fullscreen" : "macos-native-fullscreen" }
    }

    /// The command and its arguments, as the CLI takes them (not quoted). Empty for a custom command line
    private var words: [String] {
        switch self {
            case .focus(let direction): ["focus", direction.rawValue]
            case .move(let direction): ["move", direction.rawValue]
            case .joinWith(let direction): ["join-with", direction.rawValue]
            case .resize(let dimension, let amount):
                switch amount {
                    case .add(let value): ["resize", dimension.rawValue, "+\(value)"]
                    case .subtract(let value): ["resize", dimension.rawValue, "-\(value)"]
                    case .set(let value): ["resize", dimension.rawValue, "\(value)"]
                }
            case .workspace(let name): ["workspace", name]
            case .workspaceBackAndForth: ["workspace-back-and-forth"]
            case .moveWindowToWorkspace(let name): ["move-node-to-workspace", name]
            case .moveWorkspaceToMonitor(let step, let wrapAround):
                wrapAround ? ["move-workspace-to-monitor", "--wrap-around", step.rawValue] : ["move-workspace-to-monitor", step.rawValue]
            case .layout(let options): ["layout"] + options.map(\.rawValue)
            case .fullscreen(let kind): [kind.command]
            case .enterFullscreen(let kind): [kind.command, "on"]
            case .exitFullscreen(let kind): [kind.command, "off"]
            case .flattenWorkspaceTree: ["flatten-workspace-tree"]
            case .balanceSizes: ["balance-sizes"]
            case .closeWindow: ["close"]
            case .closeAllWindowsButCurrent: ["close-all-windows-but-current"]
            case .enterMode(let name): ["mode", name]
            case .reloadSettings: ["reload-config"]
            case .moveMouse(let target): ["move-mouse", target.rawValue]
            case .custom: []
        }
    }

    /// The command line of the action: shown in the settings window, and where a custom command line starts from
    var commandLine: String {
        if case .custom(let line) = self { return line }
        return words.map(\.shellQuoted).joined(separator: " ")
    }

    /// The engine command. A typed action builds it from its values, nothing is parsed; its words are kept for what the
    /// command prints (e.g. `aerospace config`, the logs). A custom command line is parsed
    @MainActor var command: ParsedCmd<Shell<any Command>> {
        let rawArgs = Array(words.dropFirst())
        let args: any CmdArgs
        switch self {
            case .focus(let direction): args = FocusCmdArgs(rawArgs: rawArgs.slice, cardinalOrDfsDirection: .direction(direction))
            case .move(let direction): args = MoveCmdArgs(rawArgs: rawArgs, direction: direction)
            case .joinWith(let direction): args = JoinWithCmdArgs(rawArgs: rawArgs, direction: direction)
            case .resize(let dimension, let amount):
                let units: ResizeCmdArgs.Units = switch amount {
                    case .add(let value): .add(value)
                    case .subtract(let value): .subtract(value)
                    case .set(let value): .set(value)
                }
                args = ResizeCmdArgs(rawArgs: rawArgs, dimension: dimension, units: units)
            case .workspace(let name), .moveWindowToWorkspace(let name):
                // E.g. `next` would be a direction
                let target: WorkspaceTarget
                switch WorkspaceName.parse(name) {
                    case .success(let name): target = .direct(name)
                    case .failure(let message): return .failure(message, EXIT_CODE_TWO)
                }
                args = if case .workspace = self {
                    WorkspaceCmdArgs(rawArgs: rawArgs.slice).with(\.target, .initialized(target))
                } else {
                    MoveNodeToWorkspaceCmdArgs(rawArgs: rawArgs.slice).with(\.target, .initialized(target))
                }
            case .workspaceBackAndForth: args = WorkspaceBackAndForthCmdArgs(rawArgs: rawArgs.slice)
            case .moveWorkspaceToMonitor(let step, let wrapAround):
                args = MoveWorkspaceToMonitorCmdArgs(rawArgs: rawArgs.slice)
                    .with(\.wrapAround, wrapAround)
                    .with(\.target, .initialized(.relative(step == .next ? .next : .prev)))
            case .layout(let options):
                if options.isEmpty { return .failure("No layout is chosen", EXIT_CODE_TWO) }
                args = LayoutCmdArgs(rawArgs: rawArgs, toggleBetween: options.map(\.layoutDescription))
            case .fullscreen(let kind): args = kind.args(rawArgs, .toggle)
            case .enterFullscreen(let kind): args = kind.args(rawArgs, .on)
            case .exitFullscreen(let kind): args = kind.args(rawArgs, .off)
            case .flattenWorkspaceTree: args = FlattenWorkspaceTreeCmdArgs(rawArgs: rawArgs.slice)
            case .balanceSizes: args = BalanceSizesCmdArgs(rawArgs: rawArgs.slice)
            case .closeWindow: args = CloseCmdArgs(rawArgs: rawArgs.slice)
            case .closeAllWindowsButCurrent: args = CloseAllWindowsButCurrentCmdArgs(rawArgs: rawArgs.slice)
            case .enterMode(let name): args = ModeCmdArgs(rawArgs: rawArgs.slice).with(\.targetMode, .initialized(name))
            case .reloadSettings: args = ReloadConfigCmdArgs(rawArgs: rawArgs.slice)
            case .moveMouse(let target): args = MoveMouseCmdArgs(rawArgs: rawArgs, mouseTarget: target)
            case .custom(let line): return parseCommand(line, allowExecAndForget: true, allowEval: false)
        }
        return args.toCommand().map { .cmd($0) }
    }
}

extension Action.LayoutOption {
    fileprivate var layoutDescription: LayoutCmdArgs.LayoutDescription {
        switch self {
            case .tiles: .tiles
            case .accordion: .accordion
            case .horizontal: .horizontal
            case .vertical: .vertical
            case .floating: .floating
            case .tiling: .tiling
        }
    }
}

extension Action.FullscreenKind {
    fileprivate func args(_ rawArgs: [String], _ toggle: ToggleEnum) -> any CmdArgs {
        switch self {
            case .marSpace: FullscreenCmdArgs(rawArgs: rawArgs, toggle: toggle)
            case .macOSNative: MacosNativeFullscreenCmdArgs(rawArgs: rawArgs.slice).with(\.toggle, toggle)
        }
    }
}

extension String {
    /// Quoted for the command language when needed (e.g. a workspace name with a space)
    fileprivate var shellQuoted: String {
        let isPlain = !isEmpty && allSatisfy { $0.isLetter || $0.isNumber || "-_.+".contains($0) }
        return isPlain ? self : "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
