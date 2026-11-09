import AppKit
import Common

// `[focus-border]` config section. Highlights the focused window with a colored border by managing JankyBorders
// (https://github.com/FelixKratz/JankyBorders), a separate tool that must be installed by the user:
//     brew install FelixKratz/formulae/borders
//
// - The section is absent: AeroSpace doesn't touch JankyBorders (e.g. the user starts it in after-startup-command)
// - enabled = true:  AeroSpace starts JankyBorders (or updates the running instance) on startup and on every config reload,
//                    and stops it when AeroSpace quits
// - enabled = false: AeroSpace stops JankyBorders

struct FocusBorder: Withable, Equatable {
    var enabled: Bool = false
    var activeColor: String = "0xffe1e3e4"
    var inactiveColor: String = "0xff494d64"
    var width: Int = 5

    /// Command line arguments for the `borders` executable
    var jankyBordersArgs: [String] {
        [
            "active_color=\(activeColor)",
            "inactive_color=\(inactiveColor)",
            "width=\(width).0",
            "hidpi=on",
        ]
    }
}

private let focusBorderParserTable: [String: any ParserProtocol<FocusBorder>] = [
    "enabled": Parser(\.enabled, parseBool),
    "active-color": Parser(\.activeColor, parseJankyBordersColor),
    "inactive-color": Parser(\.inactiveColor, parseJankyBordersColor),
    "width": Parser(\.width, parseFocusBorderWidth),
]

func parseFocusBorder(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> FocusBorder? {
    parseNonEmptyTable(raw, FocusBorder(), focusBorderParserTable, backtrace, &c)
}

/// 0xAARRGGBB
private func isHexColor(_ color: Substring) -> Bool {
    color.count == 10 && color.hasPrefix("0x") && color.dropFirst(2).allSatisfy(\.isHexDigit)
}

/// 0xAARRGGBB | glow(0xAARRGGBB) | gradient(top_left=0xAARRGGBB,bottom_right=0xAARRGGBB) | gradient(top_right=0xAARRGGBB,bottom_left=0xAARRGGBB)
func isJankyBordersColor(_ color: String) -> Bool {
    if isHexColor(color[...]) { return true }
    if color.hasPrefix("glow("), color.hasSuffix(")") { return isHexColor(color.dropFirst(5).dropLast()) }
    if color.hasPrefix("gradient("), color.hasSuffix(")") {
        let corners = color.dropFirst(9).dropLast().split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false) }
        guard corners.count == 2, corners.allSatisfy({ $0.count == 2 && isHexColor($0[1]) }) else { return false }
        let keys = corners.map { String($0[0]) }
        return keys == ["top_left", "bottom_right"] || keys == ["top_right", "bottom_left"]
    }
    return false
}

private func parseJankyBordersColor(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<String> {
    parseString(raw, backtrace).flatMap { color in
        isJankyBordersColor(color)
            ? .success(color)
            : .failure(.init(backtrace, "Can't parse color '\(color)'. Possible formats: 0xAARRGGBB, glow(0xAARRGGBB), " +
                    "gradient(top_left=0xAARRGGBB,bottom_right=0xAARRGGBB), gradient(top_right=0xAARRGGBB,bottom_left=0xAARRGGBB)"))
    }
}

private func parseFocusBorderWidth(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Int> {
    parseInt(raw, backtrace).flatMap { width in
        (1 ... 50).contains(width) ? .success(width) : .failure(.init(backtrace, "width must be in [1, 50] range"))
    }
}

@MainActor private var isFocusBorderManagedByAeroSpace = false

@MainActor func syncFocusBorder(_ config: Config) {
    if isUnitTest { return }
    switch config.focusBorder {
        case let focusBorder? where focusBorder.enabled:
            isFocusBorderManagedByAeroSpace = true
            runJankyBorders(focusBorder.jankyBordersArgs, config)
        case .some: // Explicitly disabled
            stopJankyBorders()
        case nil:
            if isFocusBorderManagedByAeroSpace { stopJankyBorders() }
    }
}

@MainActor func stopFocusBorderIfManagedByAeroSpace() {
    if isFocusBorderManagedByAeroSpace { stopJankyBorders() }
}

@MainActor private func runJankyBorders(_ args: [String], _ config: Config) {
    var env = config.execConfig.envVariables
    let path = env["PATH"] ?? ""
    let executable = (path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"])
        .map { URL(filePath: $0).appending(component: "borders") }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    guard let executable else { return } // JankyBorders isn't installed
    if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" } // Recommended by JankyBorders
    let process = Process()
    process.executableURL = executable
    process.arguments = args // If JankyBorders is already running, it updates the running instance and exits
    process.environment = env
    _ = Result { try process.run() }
}

@MainActor private func stopJankyBorders() {
    isFocusBorderManagedByAeroSpace = false
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/pkill")
    process.arguments = ["-x", "borders"]
    _ = Result { try process.run() }
}
