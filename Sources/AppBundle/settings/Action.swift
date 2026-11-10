import Common

/// What a shortcut, a window rule or an automation does. The settings window edits the typed cases with pickers;
/// ``custom(_:)`` is the escape hatch for any other command line (validated by the command parser).
///
/// An action compiles to the command language of the engine (``commandLine``): the same parser and the same commands as
/// the CLI, nothing is implemented twice
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

    /// The command line that the action compiles to
    var commandLine: String {
        switch self {
            case .focus(let direction): "focus \(direction.rawValue)"
            case .move(let direction): "move \(direction.rawValue)"
            case .joinWith(let direction): "join-with \(direction.rawValue)"
            case .resize(let dimension, let amount):
                switch amount {
                    case .add(let value): "resize \(dimension.rawValue) +\(value)"
                    case .subtract(let value): "resize \(dimension.rawValue) -\(value)"
                    case .set(let value): "resize \(dimension.rawValue) \(value)"
                }
            case .workspace(let name): "workspace \(name.shellQuoted)"
            case .workspaceBackAndForth: "workspace-back-and-forth"
            case .moveWindowToWorkspace(let name): "move-node-to-workspace \(name.shellQuoted)"
            case .moveWorkspaceToMonitor(let step, let wrapAround):
                wrapAround ? "move-workspace-to-monitor --wrap-around \(step.rawValue)" : "move-workspace-to-monitor \(step.rawValue)"
            case .layout(let options): (["layout"] + options.map(\.rawValue)).joined(separator: " ")
            case .fullscreen(let kind): kind.command
            case .enterFullscreen(let kind): "\(kind.command) on"
            case .exitFullscreen(let kind): "\(kind.command) off"
            case .flattenWorkspaceTree: "flatten-workspace-tree"
            case .balanceSizes: "balance-sizes"
            case .closeWindow: "close"
            case .closeAllWindowsButCurrent: "close-all-windows-but-current"
            case .enterMode(let name): "mode \(name.shellQuoted)"
            case .reloadSettings: "reload-config"
            case .moveMouse(let target): "move-mouse \(target.rawValue)"
            case .custom(let line): line
        }
    }

    /// The typed action that runs exactly the same command as `commandLine`, otherwise ``custom(_:)``. A candidate is read
    /// from the words of the line and accepted only if it parses to the same command (the parser decides, not the words)
    init(commandLine: String) {
        let line = commandLine.trimmingCharacters(in: .whitespaces)
        if let candidate = Self.candidate(line), candidate.commandLine == line || candidate.isEquivalent(to: line) {
            self = candidate
        } else {
            self = .custom(line)
        }
    }

    private func isEquivalent(to line: String) -> Bool {
        guard case .cmd(let original) = parseCommand(line, allowExecAndForget: true, allowEval: false),
              case .cmd(let compiled) = parseCommand(commandLine, allowExecAndForget: true, allowEval: false)
        else { return false }
        return original.strictEquals(compiled)
    }

    private static func candidate(_ line: String) -> Action? {
        // Quotes, sequences, pipes and conditions are custom command lines
        if line.contains(where: { "'\";&|()$`\\".contains($0) }) { return nil }
        let words = line.split(separator: " ").map(String.init)
        guard let name = words.first else { return nil }
        let args = Array(words.dropFirst())
        switch (name, args.count) {
            case ("focus", 1): return CardinalDirection(rawValue: args[0]).map(Action.focus)
            case ("move", 1): return CardinalDirection(rawValue: args[0]).map(Action.move)
            case ("join-with", 1): return CardinalDirection(rawValue: args[0]).map(Action.joinWith)
            case ("resize", 2):
                guard let dimension = ResizeCmdArgs.Dimension(rawValue: args[0]) else { return nil }
                let raw = args[1]
                if raw.hasPrefix("+") { return UInt(raw.dropFirst()).map { .resize(dimension, .add($0)) } }
                if raw.hasPrefix("-") { return UInt(raw.dropFirst()).map { .resize(dimension, .subtract($0)) } }
                return UInt(raw).map { .resize(dimension, .set($0)) }
            case ("workspace", 1) where !args[0].hasPrefix("-"): return .workspace(args[0])
            case ("workspace-back-and-forth", 0): return .workspaceBackAndForth
            case ("move-node-to-workspace", 1) where !args[0].hasPrefix("-"): return .moveWindowToWorkspace(args[0])
            case ("move-workspace-to-monitor", 1): return MonitorStep(rawValue: args[0]).map { .moveWorkspaceToMonitor($0, wrapAround: false) }
            case ("move-workspace-to-monitor", 2) where args[0] == "--wrap-around":
                return MonitorStep(rawValue: args[1]).map { .moveWorkspaceToMonitor($0, wrapAround: true) }
            case ("layout", 1...):
                let options = args.compactMap(LayoutOption.init(rawValue:))
                return options.count == args.count ? .layout(options) : nil
            case ("fullscreen", 0): return .fullscreen(.marSpace)
            case ("macos-native-fullscreen", 0): return .fullscreen(.macOSNative)
            case ("fullscreen", 1), ("macos-native-fullscreen", 1):
                let kind: FullscreenKind = name == "fullscreen" ? .marSpace : .macOSNative
                switch args[0] {
                    case "on": return .enterFullscreen(kind)
                    case "off": return .exitFullscreen(kind)
                    default: return nil
                }
            case ("flatten-workspace-tree", 0): return .flattenWorkspaceTree
            case ("balance-sizes", 0): return .balanceSizes
            case ("close", 0): return .closeWindow
            case ("close-all-windows-but-current", 0): return .closeAllWindowsButCurrent
            case ("mode", 1): return .enterMode(args[0])
            case ("reload-config", 0): return .reloadSettings
            case ("move-mouse", 1): return MouseTarget(rawValue: args[0]).map(Action.moveMouse)
            default: return nil
        }
    }
}

extension String {
    /// Quoted for the command language when needed (e.g. a workspace name with a space)
    fileprivate var shellQuoted: String {
        let isPlain = !isEmpty && allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        return isPlain ? self : "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
