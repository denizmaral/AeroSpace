import AppKit
import Common

/// The workspace (and the floating state) of a window, persisted across AeroSpace restarts
struct WindowPlacement: Equatable, Sendable {
    let nativeWindowId: UInt32
    let pid: Int32
    let workspace: String
    let isFloating: Bool
}

/// Immutable, memory-mapped set of window placements.
///
/// Binary format (little-endian):
/// ```
/// Header (16 bytes):
///   magic:       UInt32 "MSWP"
///   version:     UInt16 (1)
///   reserved:    UInt16
///   count:       UInt32
///   blobLength:  UInt32
/// Records (16 bytes each, sorted by nativeWindowId for binary search):
///   nativeWindowId: UInt32
///   pid:            Int32
///   nameOffset:     UInt32  (into the blob)
///   nameLength:     UInt16
///   flags:          UInt8   (bit 0: floating)
///   padding:        UInt8
/// Blob:
///   UTF-8 workspace names
/// ```
struct WindowPlacementSnapshot: Sendable {
    private let data: Data
    let count: Int
    private let blobStart: Int

    private static let magic: UInt32 = 0x5057_534D // "MSWP" little-endian
    private static let version: UInt16 = 1
    private static let headerSize = 16
    private static let recordSize = 16

    /// Validates the header. `data` can be (and normally is) a memory mapping. Nothing is copied
    init?(data: Data) {
        guard data.count >= Self.headerSize,
              data.loadLE(UInt32.self, at: 0) == Self.magic,
              data.loadLE(UInt16.self, at: 4) == Self.version
        else { return nil }
        let count = Int(data.loadLE(UInt32.self, at: 8))
        let blobLength = Int(data.loadLE(UInt32.self, at: 12))
        let blobStart = Self.headerSize + count * Self.recordSize
        guard data.count == blobStart + blobLength else { return nil }
        self.data = data
        self.count = count
        self.blobStart = blobStart
    }

    /// Binary search by the native window id. The pid protects against window ids of terminated apps
    func placement(nativeWindowId: UInt32, pid: Int32) -> WindowPlacement? {
        var low = 0
        var high = count - 1
        while low <= high {
            let mid = (low + high) / 2
            let id = data.loadLE(UInt32.self, at: Self.headerSize + mid * Self.recordSize)
            if id < nativeWindowId {
                low = mid + 1
            } else if id > nativeWindowId {
                high = mid - 1
            } else {
                let record = self.record(at: mid)
                return record.pid == pid ? record : nil
            }
        }
        return nil
    }

    var all: [WindowPlacement] { (0 ..< count).map(record(at:)) }

    private func record(at index: Int) -> WindowPlacement {
        let offset = Self.headerSize + index * Self.recordSize
        let nameOffset = Int(data.loadLE(UInt32.self, at: offset + 8))
        let nameLength = Int(data.loadLE(UInt16.self, at: offset + 12))
        let nameStart = blobStart + nameOffset
        let name = nameStart + nameLength <= data.count
            ? String(decoding: data[(data.startIndex + nameStart) ..< (data.startIndex + nameStart + nameLength)], as: UTF8.self)
            : ""
        return WindowPlacement(
            nativeWindowId: data.loadLE(UInt32.self, at: offset),
            pid: Int32(bitPattern: data.loadLE(UInt32.self, at: offset + 4)),
            workspace: name,
            isFloating: data.loadLE(UInt8.self, at: offset + 14) & 1 != 0,
        )
    }

    /// `placements` must be sorted by nativeWindowId and must not contain duplicate ids
    static func encode(_ placements: [WindowPlacement]) -> Data {
        var records = Data(capacity: placements.count * recordSize)
        var blob = Data()
        for placement in placements {
            let name = Data(placement.workspace.utf8)
            records.appendLE(placement.nativeWindowId)
            records.appendLE(UInt32(bitPattern: placement.pid))
            records.appendLE(UInt32(blob.count))
            records.appendLE(UInt16(clamping: name.count))
            records.appendLE(UInt8(placement.isFloating ? 1 : 0))
            records.appendLE(UInt8(0))
            blob.append(name.prefix(Int(UInt16.max)))
        }
        var result = Data(capacity: headerSize + records.count + blob.count)
        result.appendLE(magic)
        result.appendLE(version)
        result.appendLE(UInt16(0))
        result.appendLE(UInt32(placements.count))
        result.appendLE(UInt32(blob.count))
        result.append(records)
        result.append(blob)
        return result
    }
}

/// Remembers the workspace of every window in a memory-mapped file.
///
/// AeroSpace only sees windows on the active macOS Space, and it loses its model on restart. Without the store, the
/// windows that it detects after a restart (or later: after a native fullscreen Space, after the lock screen) are put
/// on the focused workspace. With the store, every window goes back to its own workspace.
///
/// The file of the previous run is memory-mapped once at startup (zero copy, no parsing). It's rewritten atomically
/// only when the placement of some window changes.
@MainActor
enum WindowPlacementStore {
    private static let url: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: aeroSpaceAppId, directoryHint: .isDirectory)
        .appending(path: "window-placement.bin")

    /// The placements of the previous run
    private static let previousRun: WindowPlacementSnapshot? = isUnitTest
        ? nil
        : (try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap(WindowPlacementSnapshot.init(data:))
    /// Windows of the previous run that were detected in this run
    private static var restoredWindowIds: Set<UInt32> = []
    private static var lastPersisted: [WindowPlacement] = []

    /// The placement of the window in the previous run, if the window isn't known to this run yet
    static func previousPlacement(of windowId: OpaqueWindowId, _ macApp: MacApp) -> WindowPlacement? {
        guard let previousRun, let nativeWindowId = macApp.nativeWindowId(of: windowId) else { return nil }
        let placement = previousRun.placement(nativeWindowId: nativeWindowId, pid: macApp.nsApp.processIdentifier)
        if placement != nil { restoredWindowIds.insert(nativeWindowId) }
        return placement
    }

    /// Called at the end of refresh sessions. O(windows) in-memory comparison, the file is written only on changes
    static func persistIfChanged() {
        if isUnitTest { return }
        var placements: [WindowPlacement] = []
        placements.reserveCapacity(MacWindow.allWindowsMap.count)
        for window in MacWindow.allWindowsMap.values {
            guard let nativeWindowId = window.macApp.nativeWindowId(of: window.windowId),
                  let workspace = window.nodeWorkspace?.name
            else { continue }
            placements.append(WindowPlacement(
                nativeWindowId: nativeWindowId,
                pid: window.macApp.nsApp.processIdentifier,
                workspace: workspace,
                isFloating: window.isFloating,
            ))
        }
        // E.g. the lock screen: all windows are temporarily invisible. Keep the last persisted placement
        if placements.isEmpty { return }
        // Keep the windows of the previous run that are not detected yet (e.g. on other macOS Spaces)
        if let previousRun {
            let liveIds = Set(placements.map(\.nativeWindowId))
            for placement in previousRun.all
                where !liveIds.contains(placement.nativeWindowId) &&
                !restoredWindowIds.contains(placement.nativeWindowId) &&
                NSRunningApplication(processIdentifier: placement.pid) != nil
            {
                placements.append(placement)
            }
        }
        placements.sort { $0.nativeWindowId < $1.nativeWindowId }
        if placements == lastPersisted { return }
        lastPersisted = placements
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try WindowPlacementSnapshot.encode(placements).write(to: url, options: .atomic)
        } catch {
            perfLogger.error("Can't persist window placement: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Data {
    /// Little-endian load at a byte offset (unaligned). The caller checks the bounds
    func loadLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = 0
        for byteIndex in 0 ..< MemoryLayout<T>.size {
            value |= T(self[startIndex + offset + byteIndex]) << (byteIndex * 8)
        }
        return value
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        for byteIndex in 0 ..< MemoryLayout<T>.size {
            append(UInt8(truncatingIfNeeded: value >> (byteIndex * 8)))
        }
    }
}
