import AppKit
import Carbon
import HotKey

/// The labels of the keys on the current keyboard layout of macOS (QWERTZ, AZERTY, Dvorak, …): a shortcut is stored by its
/// physical key, it's shown with what is printed on that key
@MainActor
enum KeyLabels {
    /// E.g. ⌃⌥Z on a Swiss German keyboard for the key that is Y on a US keyboard
    static func symbols(_ chord: KeyChord) -> String {
        var result = ""
        if chord.modifiers.contains(.control) { result += "⌃" }
        if chord.modifiers.contains(.option) { result += "⌥" }
        if chord.modifiers.contains(.shift) { result += "⇧" }
        if chord.modifiers.contains(.command) { result += "⌘" }
        return result + label(chord.key)
    }

    static func label(_ key: Key) -> String {
        if let special = special[key] { return special }
        return typedCharacter(key.carbonKeyCode).map { $0.uppercased() } ?? key.description
    }

    private static let special: [Key: String] = [
        .return: "↩", .tab: "⇥", .space: "Space", .delete: "⌫", .forwardDelete: "⌦", .escape: "⎋",
        .leftArrow: "←", .rightArrow: "→", .upArrow: "↑", .downArrow: "↓",
        .home: "↖", .end: "↘", .pageUp: "⇞", .pageDown: "⇟", .keypadEnter: "⌤",
    ]

    /// The character that the key types without modifiers on the current keyboard layout
    private static func typedCharacter(_ keyCode: UInt32) -> String? {
        guard let source = unsafe TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = unsafe TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = unsafe Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = unsafe layoutData.withUnsafeBytes { bytes in
            unsafe UCKeyTranslate(
                bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters,
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(decoding: characters.prefix(length), as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return text.isEmpty ? nil : text
    }
}
