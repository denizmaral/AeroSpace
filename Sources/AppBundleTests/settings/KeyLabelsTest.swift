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
    }
}
