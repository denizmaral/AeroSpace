@testable import AppBundle
import Foundation
import SwiftUI
import Testing

/// The settings window binds, edits and removes by id (IdentifiedList): a view of a removed element (a closing popover, a
/// text field that ends editing) reads its last value and writes nothing. SwiftUI builds the content of a closing popover
/// again after its element was removed: by index, it read past the end (a crash when a window rule was deleted)
@MainActor
@Suite
struct SettingsBindingTest {
    @MainActor private final class Rows {
        var values: IdentifiedList<Int> = [1, 2, 3]
    }

    @Test func testElementOfARemovedRow() {
        let rows = Rows()
        let list = Binding(get: { rows.values }, set: { rows.values = $0 })
        let thirdId = rows.values.ids[2]
        let third = list.element(thirdId, or: 0)
        rows.values[id: thirdId] = nil
        assertEquals(third.wrappedValue, 3) // The last value
        third.wrappedValue = 9 // Writes nothing
        assertEquals(Array(rows.values), [1, 2])
        // Created after the element was removed
        let removed = list.element(thirdId, or: 0)
        assertEquals(removed.wrappedValue, 0)
        removed.wrappedValue = 9
        assertEquals(Array(rows.values), [1, 2])
        // An element that is there is read and written, wherever it moved
        let firstId = rows.values.ids[0]
        rows.values.move(fromOffsets: [0], toOffset: 2)
        list.element(firstId, or: 0).wrappedValue = 7
        assertEquals(Array(rows.values), [2, 7])
    }

    /// The ids stay with their elements, whatever changes the list
    @Test func testIdsFollowTheirElements() {
        var list: IdentifiedList<String> = ["a", "b", "c"]
        let (a, b, c) = (list.ids[0], list.ids[1], list.ids[2])
        list.move(fromOffsets: [2], toOffset: 0)
        assertEquals(list.ids, [c, a, b])
        list.swapAt(0, 2)
        assertEquals(Array(list), ["b", "a", "c"])
        assertEquals(list.ids, [b, a, c])
        list.sort()
        assertEquals(list.ids, [a, b, c])
        list[1] = "B" // In place
        assertEquals(list[id: b], "B")
        list.removeAll { $0 == "a" }
        assertEquals(list.ids, [b, c])
        list.append("d")
        assertEquals(list.count, 3)
        #expect(!Set([a, b, c]).contains(list.lastId!)) // A new element, a new id
    }

    /// Stored as a plain array: the file format doesn't know the ids. And they don't count for equality
    @Test func testAPlainArrayOnDiskAndEqualityWithoutIds() throws {
        let list: IdentifiedList<Int> = [1, 2]
        let encoded = try JSONEncoder().encode(list)
        assertEquals(String(decoding: encoded, as: UTF8.self), "[1,2]")
        let decoded = try JSONDecoder().decode(IdentifiedList<Int>.self, from: encoded)
        assertEquals(decoded, list)
        #expect(decoded.ids != list.ids)
    }

    /// Esc cancels the recording of a shortcut, also with Caps Lock on (it was recorded as the shortcut then)
    @Test func testEscCancelsTheRecordingOfAShortcut() {
        assertEquals(KeyChordRecorder.cancelsRecording(keyCode: 53, []), true)
        assertEquals(KeyChordRecorder.cancelsRecording(keyCode: 53, [.capsLock]), true)
        assertEquals(KeyChordRecorder.cancelsRecording(keyCode: 53, [.capsLock, .function, .numericPad]), true)
        assertEquals(KeyChordRecorder.cancelsRecording(keyCode: 53, [.control]), false) // ⌃Esc is a shortcut
        assertEquals(KeyChordRecorder.cancelsRecording(keyCode: 53, [.capsLock, .shift]), false)
        assertEquals(KeyChordRecorder.cancelsRecording(keyCode: 0, []), false) // A
    }
}
