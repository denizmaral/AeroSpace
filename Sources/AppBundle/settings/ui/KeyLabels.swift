import AppKit
import Carbon
import Common
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

    /// Per key code, for the current keyboard layout: asking the layout is expensive, a list shows hundreds of keys
    private static var labels: [UInt32: String] = [:]

    /// The key that types the character, per character, for the current keyboard layout
    private static var keysByLabel: [String: Key]? = nil

    /// The keyboard layout of macOS changed
    static func layoutChanged() {
        labels = [:]
        keysByLabel = nil
    }

    /// The key that types the character (a letter, a digit, …) on the keyboard layout of macOS. Not the keypad
    static func key(typing character: String) -> Key? {
        if keysByLabel == nil {
            let keypad = UInt32(kVK_ANSI_KeypadDecimal) ... UInt32(kVK_ANSI_Keypad9)
            let labels = (UInt32(0) ..< 128).compactMap { code -> (Key, String)? in
                guard !keypad.contains(code), let key = Key(carbonKeyCode: code), special[key] == nil else { return nil }
                return (key, label(key))
            }
            keysByLabel = keysByCharacter(labels)
        }
        return keysByLabel?[character.uppercased()]
    }

    /// The key that types each character, from the label of every key (in key code order: the first key wins). A letter or a
    /// digit that no key types without modifiers (the digits of AZERTY, the Latin letters of a Cyrillic layout) is the key at
    /// its place on a US keyboard, unless that key types another letter or digit
    nonisolated static func keysByCharacter(_ labels: [(key: Key, label: String)]) -> [String: Key] {
        var keys: [String: Key] = [:]
        for (key, label) in labels where keys[label] == nil {
            keys[label] = key
        }
        let latin = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".map(String.init))
        let labelOfKey = Dictionary(labels.map { ($0.key, $0.label) }, uniquingKeysWith: { first, _ in first })
        let us = getKeysPreset(.qwerty)
        for character in latin.sorted() where keys[character] == nil {
            guard let key = us[character.lowercased()], let label = labelOfKey[key], !latin.contains(label) else { continue }
            keys[character] = key
        }
        return keys
    }

    static func label(_ key: Key) -> String {
        if let special = special[key] { return special }
        if let label = labels[key.carbonKeyCode] { return label }
        let label = typedCharacter(key.carbonKeyCode).map { $0.uppercased() } ?? key.description
        labels[key.carbonKeyCode] = label
        return label
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

/// When the keyboard layout of macOS changes, the key labels follow it, and so do the keys of the workspace shortcuts (the
/// key that types the name of the workspace): the settings are applied again
@MainActor
func startObservingKeyboardLayout() {
    DistributedNotificationCenter.default().addObserver(
        forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main,
    ) { _ in
        MainActor.assumeIsolated {
            KeyLabels.layoutChanged()
            SettingsWindowController.shared.keyboardLayoutChanged()
            Task.startUnstructured { await SettingsStore.shared.reapply() }
        }
    }
}
