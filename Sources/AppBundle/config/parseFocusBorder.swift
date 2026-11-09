import AppKit
import Common

/// `[focus-border]` config section. A colored border around the focused window, drawn by AeroSpace itself
struct FocusBorder: Withable, Equatable {
    var enabled: Bool = false
    var color: FocusBorderColor = .solid(0xFF33_CCFF)
    var width: Int = 4
    /// Corner radius of the windows. The border follows it
    var radius: Int = 12
}

enum FocusBorderColor: Equatable {
    /// 0xAARRGGBB
    case solid(UInt32)
    /// `fromTopLeft == true`: from the top left corner to the bottom right corner.
    /// `fromTopLeft == false`: from the top right corner to the bottom left corner
    case gradient(start: UInt32, end: UInt32, fromTopLeft: Bool)
}

private let focusBorderParserTable: [String: any ParserProtocol<FocusBorder>] = [
    "enabled": Parser(\.enabled, parseBool),
    "color": Parser(\.color, parseFocusBorderColorConfig),
    "width": Parser(\.width, { raw, backtrace in parseInt(raw, backtrace, in: 1 ... 20) }),
    "radius": Parser(\.radius, { raw, backtrace in parseInt(raw, backtrace, in: 0 ... 50) }),
]

func parseFocusBorder(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> FocusBorder {
    parseNonEmptyTable(raw, FocusBorder(), focusBorderParserTable, backtrace, &c)
}

private func parseInt(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, in range: ClosedRange<Int>) -> ResOrConfigParseDiagnostic<Int> {
    parseInt(raw, backtrace).flatMap { value in
        range.contains(value) ? .success(value) : .failure(.init(backtrace, "Must be in [\(range.lowerBound), \(range.upperBound)] range"))
    }
}

private func parseFocusBorderColorConfig(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<FocusBorderColor> {
    parseString(raw, backtrace).flatMap { color in
        parseFocusBorderColor(color).toResult(.init(
            backtrace,
            "Can't parse color '\(color)'. Possible formats: 0xAARRGGBB, " +
                "gradient(top_left=0xAARRGGBB,bottom_right=0xAARRGGBB), gradient(top_right=0xAARRGGBB,bottom_left=0xAARRGGBB)",
        ))
    }
}

func parseFocusBorderColor(_ raw: String) -> FocusBorderColor? {
    if let color = parseArgbColor(raw[...]) { return .solid(color) }
    guard raw.hasPrefix("gradient("), raw.hasSuffix(")") else { return nil }
    let corners = raw.dropFirst("gradient(".count).dropLast().split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false) }
    guard corners.count == 2,
          corners.allSatisfy({ $0.count == 2 }),
          let start = parseArgbColor(corners[0][1]),
          let end = parseArgbColor(corners[1][1])
    else { return nil }
    return switch (corners[0][0], corners[1][0]) {
        case ("top_left", "bottom_right"): .gradient(start: start, end: end, fromTopLeft: true)
        case ("top_right", "bottom_left"): .gradient(start: start, end: end, fromTopLeft: false)
        default: nil
    }
}

/// 0xAARRGGBB
private func parseArgbColor(_ raw: Substring) -> UInt32? {
    guard raw.count == 10, raw.hasPrefix("0x") else { return nil }
    let hex = raw.dropFirst(2)
    return hex.allSatisfy(\.isHexDigit) ? UInt32(hex, radix: 16) : nil
}

extension UInt32 {
    /// 0xAARRGGBB
    var argbCgColor: CGColor {
        CGColor(
            srgbRed: CGFloat((self >> 16) & 0xFF) / 255,
            green: CGFloat((self >> 8) & 0xFF) / 255,
            blue: CGFloat(self & 0xFF) / 255,
            alpha: CGFloat((self >> 24) & 0xFF) / 255,
        )
    }
}
