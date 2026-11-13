import AppKit
import Common

/// The workspace (and the floating state) of a window, persisted across AeroSpace restarts
struct WindowPlacement: Equatable, Sendable {
    let nativeWindowId: UInt32
    let pid: Int32
    let workspace: String
    let isFloating: Bool
    /// See ``PinCommand``
    var isPinned = false
}

/// Immutable, memory-mapped set of window placements, and the tiling trees of the workspaces.
///
/// Binary format (little-endian):
/// ```
/// Header (28 bytes; 24 bytes in version 2, which has no trees):
///   magic:       UInt32 "MSWP"
///   version:     UInt16 (3)
///   reserved:    UInt16
///   count:       UInt32
///   blobLength:  UInt32
///   bootSession: UInt64  (FNV-1a of kern.bootsessionuuid. Window ids and pids are reused after a reboot)
///   treesLength: UInt32
/// Records (16 bytes each, sorted by nativeWindowId for binary search):
///   nativeWindowId: UInt32
///   pid:            Int32
///   nameOffset:     UInt32  (into the blob)
///   nameLength:     UInt16
///   flags:          UInt8   (bit 0: floating, bit 1: pinned)
///   padding:        UInt8
/// Blob:
///   UTF-8 workspace names
/// Trees (see ``TilingTreeSnapshot``)
/// ```
struct WindowPlacementSnapshot: Sendable {
    private let data: Data
    let count: Int
    let bootSession: UInt64
    private let headerSize: Int
    private let blobStart: Int
    private let treesStart: Int

    private static let magic: UInt32 = 0x5057_534D // "MSWP" little-endian
    private static let version: UInt16 = 3
    /// Still read: the file that the previous version of MarSpace wrote, when MarSpace is updated
    private static let versionWithoutTrees: UInt16 = 2
    private static let headerSize = 28
    private static let headerSizeWithoutTrees = 24
    private static let recordSize = 16

    /// Validates the header. `data` can be (and normally is) a memory mapping. Nothing is copied
    init?(data: Data) {
        guard data.count >= Self.headerSizeWithoutTrees, data.loadLE(UInt32.self, at: 0) == Self.magic else { return nil }
        let headerSize: Int
        switch data.loadLE(UInt16.self, at: 4) {
            case Self.version: headerSize = Self.headerSize
            case Self.versionWithoutTrees: headerSize = Self.headerSizeWithoutTrees
            default: return nil
        }
        guard data.count >= headerSize else { return nil }
        let count = Int(data.loadLE(UInt32.self, at: 8))
        let blobLength = Int(data.loadLE(UInt32.self, at: 12))
        let treesLength = headerSize == Self.headerSize ? Int(data.loadLE(UInt32.self, at: 24)) : 0
        let blobStart = headerSize + count * Self.recordSize
        guard data.count == blobStart + blobLength + treesLength else { return nil }
        self.data = data
        self.count = count
        self.bootSession = data.loadLE(UInt64.self, at: 16)
        self.headerSize = headerSize
        self.blobStart = blobStart
        self.treesStart = blobStart + blobLength
    }

    /// The tiling trees of the workspaces. Empty if there are none, or if they can't be read
    var trees: [PersistedTilingTree] {
        treesStart == data.count ? [] : [PersistedTilingTree](decoding: data[(data.startIndex + treesStart)...]) ?? []
    }

    /// Binary search by the native window id. The pid protects against window ids of terminated apps
    func placement(nativeWindowId: UInt32, pid: Int32) -> WindowPlacement? {
        var low = 0
        var high = count - 1
        while low <= high {
            let mid = (low + high) / 2
            let id = data.loadLE(UInt32.self, at: headerSize + mid * Self.recordSize)
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
        let offset = headerSize + index * Self.recordSize
        let nameOffset = Int(data.loadLE(UInt32.self, at: offset + 8))
        let nameLength = Int(data.loadLE(UInt16.self, at: offset + 12))
        let nameStart = blobStart + nameOffset
        let name = nameStart + nameLength <= treesStart
            ? String(decoding: data[(data.startIndex + nameStart) ..< (data.startIndex + nameStart + nameLength)], as: UTF8.self)
            : ""
        return WindowPlacement(
            nativeWindowId: data.loadLE(UInt32.self, at: offset),
            pid: Int32(bitPattern: data.loadLE(UInt32.self, at: offset + 4)),
            workspace: name,
            isFloating: data.loadLE(UInt8.self, at: offset + 14) & 1 != 0,
            isPinned: data.loadLE(UInt8.self, at: offset + 14) & 2 != 0,
        )
    }

    /// `placements` must be sorted by nativeWindowId and must not contain duplicate ids
    static func encode(_ placements: [WindowPlacement], trees: [PersistedTilingTree] = [], bootSession: UInt64) -> Data {
        let trees = trees.isEmpty ? Data() : trees.encoded()
        var records = Data(capacity: placements.count * recordSize)
        var blob = Data()
        for placement in placements {
            let name = Data(placement.workspace.utf8)
            records.appendLE(placement.nativeWindowId)
            records.appendLE(UInt32(bitPattern: placement.pid))
            records.appendLE(UInt32(blob.count))
            records.appendLE(UInt16(clamping: name.count))
            records.appendLE(UInt8((placement.isFloating ? 1 : 0) | (placement.isPinned ? 2 : 0)))
            records.appendLE(UInt8(0))
            blob.append(name.prefix(Int(UInt16.max)))
        }
        var result = Data(capacity: headerSize + records.count + blob.count + trees.count)
        result.appendLE(magic)
        result.appendLE(version)
        result.appendLE(UInt16(0))
        result.appendLE(UInt32(placements.count))
        result.appendLE(UInt32(blob.count))
        result.appendLE(bootSession)
        result.appendLE(UInt32(trees.count))
        result.append(records)
        result.append(blob)
        result.append(trees)
        return result
    }
}

/// Remembers the workspace of every window, and the tiling tree of every workspace, in a memory-mapped file.
///
/// AeroSpace only sees windows on the active macOS Space, and it loses its model on restart. Without the store, the
/// windows that it detects after a restart (or later: after a native fullscreen Space, after the lock screen) are put
/// on the focused workspace. With the store, every window goes back to its own workspace, and the windows that are
/// there when MarSpace starts go back to their places in the layout, with their sizes
/// (``restoreTilingTreesOfPreviousRunIfPending()``).
///
/// The file of the previous run is memory-mapped once at startup (zero copy, no parsing). It's rewritten atomically
/// only when the placement of some window changes.
@MainActor
enum WindowPlacementStore {
    private static let url: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: aeroSpaceAppId, directoryHint: .isDirectory)
        .appending(path: "window-placement.bin")

    /// Identifies the macOS boot session. Window ids and pids are reused after a reboot, the placements of another boot
    /// are useless. Unlike kern.boottime, the boot session uuid doesn't shift when the clock is adjusted
    private static let bootSession: UInt64 = {
        var buffer = [UInt8](repeating: 0, count: 64)
        var size = buffer.count
        guard unsafe sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return 0 }
        return buffer.prefix { $0 != 0 }.reduce(0xCBF2_9CE4_8422_2325 as UInt64) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
    }()

    /// The placements of the previous run (of this boot)
    private static let previousRun: WindowPlacementSnapshot? = isUnitTest
        ? nil
        : (try? Data(contentsOf: url, options: .mappedIfSafe))
            .flatMap(WindowPlacementSnapshot.init(data:))
            .flatMap { $0.bootSession == bootSession ? $0 : nil }
    /// Windows of the previous run that were detected in this run
    private static var restoredWindowIds: Set<UInt32> = []
    private static var lastPersisted: [WindowPlacement] = []
    private static var lastPersistedTrees: [PersistedTilingTree] = []
    private static var didRestoreTilingTrees = false

    /// Puts the tiling windows back where they were in the layout of the previous run. Done once, when the windows that
    /// are there at the start of MarSpace are registered (in an arbitrary order, each one placed like a new window), before
    /// the first layout and before the placements are persisted again. A window that shows up later (it was on another
    /// macOS Space) goes to its workspace, as a new window. Only the first call restores: the session that follows the
    /// startup session is a startup session too, and the layout may have changed meanwhile (the commands after startup)
    ///
    /// The windows of the previous run may not be there yet: the screen is locked when MarSpace starts (it sees no window
    /// then), or a macOS fullscreen Space is shown. Then the complete refresh sessions try again, until one of them sees a
    /// window of the previous run (the screen is unlocked). The trees were restored only by the startup session: after a
    /// restart behind the lock screen, the windows came back as new windows, without their layout
    static func restoreTilingTreesOfPreviousRunIfPending() {
        if didRestoreTilingTrees { return }
        guard let previousRun else {
            didRestoreTilingTrees = true
            return
        }
        let isAnyWindowOfPreviousRunThere = MacWindow.allWindowsMap.values.contains { window in
            nativeWindowId(of: window).flatMap { previousRun.placement(nativeWindowId: $0, pid: window.macApp.pid) } != nil
        }
        guard isAnyWindowOfPreviousRunThere else { return }
        didRestoreTilingTrees = true
        for tree in previousRun.trees {
            Workspace.get(byName: tree.workspace).restoreTilingTree(tree, windowId: nativeWindowId(of:))
        }
        // The focus was taken from macOS before: the focused window stays the most recent one of its workspace
        globalFocus.windowOrNil?.markAsMostRecentChild()
    }

    private static func nativeWindowId(of window: Window) -> UInt32? {
        (window as? MacWindow).flatMap { $0.macApp.nativeWindowId(of: $0.windowId) }
    }

    /// The placement of the window in the previous run. Only the first registration of the window in this run is
    /// restored (see ``markRestored(_:_:)``): later, the window may be moved, its previous run placement is outdated
    static func previousPlacement(of windowId: OpaqueWindowId, _ macApp: MacApp) -> WindowPlacement? {
        guard let previousRun,
              let nativeWindowId = macApp.nativeWindowId(of: windowId),
              !restoredWindowIds.contains(nativeWindowId)
        else { return nil }
        return previousRun.placement(nativeWindowId: nativeWindowId, pid: macApp.pid)
    }

    /// Call it after the window with the previous placement is registered (the registration may be canceled before)
    static func markRestored(_ windowId: OpaqueWindowId, _ macApp: MacApp) {
        if let nativeWindowId = macApp.nativeWindowId(of: windowId) { restoredWindowIds.insert(nativeWindowId) }
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
                pid: window.macApp.pid,
                workspace: workspace,
                isFloating: window.isFloating,
                isPinned: window.isPinned,
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
                RunningApps.isRunning(pid: placement.pid)
            {
                placements.append(placement)
            }
        }
        placements.sort { $0.nativeWindowId < $1.nativeWindowId }
        // While a window is resized with the mouse, every mouse move changes the weights: the trees are persisted when
        // the button is released (a refresh session follows)
        let trees = currentlyManipulatedWithMouseWindowId == nil
            ? Workspace.all.compactMap { $0.tilingTreeSnapshot(windowId: nativeWindowId(of:)) }
            : lastPersistedTrees
        if placements == lastPersisted && trees == lastPersistedTrees { return }
        lastPersisted = placements
        lastPersistedTrees = trees
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try WindowPlacementSnapshot.encode(placements, trees: trees, bootSession: bootSession).write(to: url, options: .atomic)
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
