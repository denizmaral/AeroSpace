@testable import AppBundle
import HotKey
import Testing

/// The labels come from the keyboard layout of macOS on the machine (QWERTY, QWERTZ, AZERTY, …): only what holds for all of
/// them is checked
@MainActor
@Suite
struct KeyLabelsTest {
    @Test func testLabels() {
        assertEquals(KeyLabels.label(.leftArrow), "←")
        assertEquals(KeyLabels.label(.return), "↩")
        assertEquals(KeyLabels.label(.space), "Space")
        for key in [Key.a, .h, .z, .y] {
            let label = KeyLabels.label(key)
            assertEquals(label.count, 1)
            assertEquals(label, label.uppercased())
        }
        assertEquals(KeyLabels.symbols(KeyChord([.control, .option, .shift], .leftArrow)), "⌃⌥⇧←")
        // On any layout of the machine, every workspace named with a letter or a digit has a key
        for character in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" {
            #expect(KeyLabels.key(typing: String(character)) != nil, "no key for \(character)")
        }
    }

    private let usKeys = keyNotationToKeyCode

    /// A layout as the labels of the keys, from the US labels: `changes` maps a US label to the label on this layout
    private func layout(_ changes: [String: String]) -> [(key: Key, label: String)] {
        "abcdefghijklmnopqrstuvwxyz0123456789".map(String.init).compactMap { name in
            usKeys[name].map { ($0, changes[name.uppercased()] ?? name.uppercased()) }
        }
    }

    /// Every letter and digit is typed by a key: nothing falls back (Z is where a US keyboard has Y)
    @Test func testSwissGermanTypesEveryCharacter() {
        let keys = KeyLabels.keysByCharacter(layout(["Y": "Z", "Z": "Y"]))
        assertEquals(keys["Z"], .y)
        assertEquals(keys["Y"], .z)
        assertEquals(keys["1"], .one)
        assertEquals(keys.count, 36)
    }

    /// The digits of AZERTY need shift: they are the keys of the digit row. A and Q are swapped, M is typed elsewhere
    @Test func testAzertyDigitsAreTheDigitRow() {
        let keys = KeyLabels.keysByCharacter(layout([
            "1": "&", "2": "É", "3": "\"", "4": "'", "5": "(", "6": "§", "7": "È", "8": "!", "9": "Ç", "0": "À",
            "A": "Q", "Q": "A", "W": "Z", "Z": "W", "M": ",",
        ]) + [(.semicolon, "M")])
        assertEquals(keys["1"], .one)
        assertEquals(keys["0"], .zero)
        assertEquals(keys["A"], .q)
        assertEquals(keys["M"], .semicolon)
    }

    /// No key types a Latin letter on a Cyrillic layout: the letters are the keys at their US places
    @Test func testCyrillicLettersAreTheirUsPlaces() {
        let keys = KeyLabels.keysByCharacter(layout(["A": "Ф", "S": "Ы", "H": "Р", "T": "Е"]))
        assertEquals(keys["A"], .a)
        assertEquals(keys["H"], .h)
        assertEquals(keys["T"], .t)
    }
}
