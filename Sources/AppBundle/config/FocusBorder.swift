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
