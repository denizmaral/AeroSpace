@testable import AppBundle
import SwiftUI
import Testing

/// The views of a removed row (a closing popover, a text field that ends editing) must not read past the end of the list.
/// SwiftUI builds the content of a closing popover again after its row was removed: the crash when a window rule was deleted
@MainActor
@Suite
struct SettingsBindingTest {
    @MainActor private final class Rows {
        var values = [1, 2, 3]
    }

    @Test func testElementOfARemovedRow() {
        let rows = Rows()
        let list = Binding(get: { rows.values }, set: { rows.values = $0 })
        let third = list.element(2, or: 0)
        rows.values.removeLast()
        assertEquals(third.wrappedValue, 3) // The last value
        third.wrappedValue = 9 // Writes nothing
        assertEquals(rows.values, [1, 2])
        // Created after the row was removed
        let removed = list.element(2, or: 0)
        assertEquals(removed.wrappedValue, 0)
        removed.wrappedValue = 9
        assertEquals(rows.values, [1, 2])
        // A row that exists is read and written
        let first = list.element(0, or: 0)
        first.wrappedValue = 7
        assertEquals(rows.values, [7, 2])
    }
}
