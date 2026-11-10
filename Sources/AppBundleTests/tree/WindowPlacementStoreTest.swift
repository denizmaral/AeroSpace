@testable import AppBundle
import Foundation
import Testing

struct WindowPlacementStoreTest {
    private let placements = [
        WindowPlacement(nativeWindowId: 7, pid: 100, workspace: "1", isFloating: false),
        WindowPlacement(nativeWindowId: 42, pid: 200, workspace: "T", isFloating: false),
        WindowPlacement(nativeWindowId: 43, pid: 200, workspace: "Übersicht 📋", isFloating: true),
        WindowPlacement(nativeWindowId: 0xFFFF_FFFF, pid: -1, workspace: "", isFloating: true),
    ]

    @Test func testRoundTrip() throws {
        let snapshot = try #require(WindowPlacementSnapshot(data: WindowPlacementSnapshot.encode(placements, bootSession: 1_762_700_000)))
        assertEquals(snapshot.count, 4)
        assertEquals(snapshot.bootSession, 1_762_700_000)
        assertEquals(snapshot.all, placements)
    }

    @Test func testLookup() throws {
        let snapshot = try #require(WindowPlacementSnapshot(data: WindowPlacementSnapshot.encode(placements, bootSession: 1_762_700_000)))
        for placement in placements {
            assertEquals(snapshot.placement(nativeWindowId: placement.nativeWindowId, pid: placement.pid), placement)
        }
        assertNil(snapshot.placement(nativeWindowId: 8, pid: 100))
        assertNil(snapshot.placement(nativeWindowId: 0, pid: 100))
        // The window id belongs to another (terminated) process
        assertNil(snapshot.placement(nativeWindowId: 42, pid: 201))
    }

    @Test func testEmpty() throws {
        let snapshot = try #require(WindowPlacementSnapshot(data: WindowPlacementSnapshot.encode([], bootSession: 0)))
        assertEquals(snapshot.count, 0)
        assertNil(snapshot.placement(nativeWindowId: 1, pid: 1))
    }

    @Test func testRejectsCorruptedData() {
        let data = WindowPlacementSnapshot.encode(placements, bootSession: 1_762_700_000)
        #expect(WindowPlacementSnapshot(data: Data()) == nil)
        #expect(WindowPlacementSnapshot(data: data.dropLast()) == nil) // Truncated
        #expect(WindowPlacementSnapshot(data: data + [0]) == nil) // Trailing garbage
        var badMagic = data
        badMagic[0] ^= 0xFF
        #expect(WindowPlacementSnapshot(data: badMagic) == nil)
        var badVersion = data
        badVersion[4] = 99
        #expect(WindowPlacementSnapshot(data: badVersion) == nil)
    }

    /// The mapping of a file is a Data slice that doesn't start at index 0
    @Test func testSliceWithNonZeroStartIndex() throws {
        let encoded = WindowPlacementSnapshot.encode(placements, bootSession: 1_762_700_000)
        let slice = (Data([0xAB, 0xCD]) + encoded).dropFirst(2)
        let snapshot = try #require(WindowPlacementSnapshot(data: Data(slice)))
        assertEquals(snapshot.all, placements)
        let rawSlice = try #require(WindowPlacementSnapshot(data: slice))
        assertEquals(rawSlice.all, placements)
    }

    @Test func testLittleEndian() {
        var data = Data()
        data.appendLE(UInt32(0x0102_0304))
        assertEquals(Array(data), [0x04, 0x03, 0x02, 0x01])
        assertEquals(data.loadLE(UInt32.self, at: 0), 0x0102_0304)
    }
}
