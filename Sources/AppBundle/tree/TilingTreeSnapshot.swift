import AppKit
import Common

/// The tiling tree of a workspace, persisted across restarts of MarSpace (see ``WindowPlacementStore``): where every
/// window was in the layout, and how big. The windows are identified by their native window ids, which survive a restart
/// of MarSpace (not a reboot)
struct TilingTreeSnapshot: Equatable, Sendable {
    let workspace: String
    /// The window that gets the focus when the workspace is shown
    let mostRecentWindow: UInt32?
    let root: Container

    struct Container: Equatable, Sendable {
        let orientation: Orientation
        let layout: Layout
        let weight: CGFloat
        let children: [Node]
    }

    indirect enum Node: Equatable, Sendable {
        case window(nativeWindowId: UInt32, weight: CGFloat)
        case container(Container)
    }
}

extension Workspace {
    /// - Parameter nativeWindowId: the native id of a window. A window without one is left out
    /// - Returns: nil if the workspace has no tiling windows
    @MainActor
    func tilingTreeSnapshot(nativeWindowId: (Window) -> UInt32?) -> TilingTreeSnapshot? {
        guard let root = rootTilingContainer.snapshot(nativeWindowId) else { return nil }
        return TilingTreeSnapshot(
            workspace: name,
            mostRecentWindow: rootTilingContainer.mostRecentWindowRecursive.flatMap(nativeWindowId),
            root: root,
        )
    }

    /// Puts the tiling windows of the workspace back where they were in `snapshot`, with their sizes.
    ///
    /// Only the windows that are tiling windows of this workspace right now are moved: a window that a window rule floated
    /// or moved to another workspace stays there. The windows of the snapshot that are gone are left out (the normalization
    /// flattens what remains), and the tiling windows that the snapshot doesn't know are placed like new windows, after the
    /// others
    ///
    /// - Parameter nativeWindowId: the native id of a window
    @MainActor
    func restoreTilingTree(_ snapshot: TilingTreeSnapshot, nativeWindowId: (Window) -> UInt32?) {
        let previousRoot = rootTilingContainer
        let tilingWindows = previousRoot.allLeafWindowsRecursive
        var known: [UInt32: Window] = [:]
        for window in tilingWindows {
            if let id = nativeWindowId(window) { known[id] = window }
        }
        guard snapshot.root.contains(anyOf: known) else { return } // Nothing to restore: the tree stays as it is

        previousRoot.unbindFromParent() // A workspace has one root. The windows that aren't restored are still in it
        let root = TilingContainer(parent: self, adaptiveWeight: 1, snapshot.root.orientation, snapshot.root.layout, index: INDEX_BIND_LAST)
        var restored: Set<UInt32> = []
        root.restoreChildren(of: snapshot.root, known, &restored)
        snapshot.mostRecentWindow.flatMap { known[$0] }?.markAsMostRecentChild()
        // Opened while MarSpace wasn't running: next to the window that was the most recent one, like any new window
        for window in tilingWindows where nativeWindowId(window).map(restored.contains) != true {
            window.bindAsNewTilingWindow(to: self)
        }
    }
}

extension TilingContainer {
    @MainActor
    fileprivate func snapshot(_ nativeWindowId: (Window) -> UInt32?) -> TilingTreeSnapshot.Container? {
        let orientation = orientation
        let children: [TilingTreeSnapshot.Node] = children.compactMap { child in
            switch child.tilingTreeNodeCasesOrDie() {
                case .window(let window):
                    nativeWindowId(window).map { .window(nativeWindowId: $0, weight: child.getWeight(orientation)) }
                case .tilingContainer(let container):
                    container.snapshot(nativeWindowId).map { .container($0) }
            }
        }
        if children.isEmpty { return nil }
        let weight = (parent as? TilingContainer).map { getWeight($0.orientation) } ?? 1
        return TilingTreeSnapshot.Container(orientation: orientation, layout: layout, weight: weight, children: children)
    }

    @MainActor
    fileprivate func restoreChildren(of snapshot: TilingTreeSnapshot.Container, _ known: [UInt32: Window], _ restored: inout Set<UInt32>) {
        for child in snapshot.children {
            switch child {
                case .window(let id, let weight):
                    // The same id twice (a damaged file): the window is where it was put first
                    guard let window = known[id], restored.insert(id).inserted else { continue }
                    window.dwindleSplitAnchor = nil // Of the placement as a new window, which the restored tree replaces
                    window.bind(to: self, adaptiveWeight: weight, index: INDEX_BIND_LAST)
                case .container(let container):
                    guard container.contains(anyOf: known) else { continue }
                    TilingContainer(parent: self, adaptiveWeight: container.weight, container.orientation, container.layout, index: INDEX_BIND_LAST)
                        .restoreChildren(of: container, known, &restored)
            }
        }
    }
}

extension TilingTreeSnapshot.Container {
    fileprivate func contains(anyOf known: [UInt32: Window]) -> Bool {
        children.contains { child in
            switch child {
                case .window(let id, _): known[id] != nil
                case .container(let container): container.contains(anyOf: known)
            }
        }
    }
}

// MARK: - Binary format

/// The trees section of the window placement file (little-endian):
/// ```
/// workspaceCount: UInt16
/// Per workspace:
///   nameLength:       UInt16
///   name:             UTF-8
///   mostRecentWindow: UInt32 (0: none)
///   root:             Container, without its kind byte
/// Node:
///   kind:             UInt8 (0: window, 1: container)
/// Window:
///   nativeWindowId:   UInt32
///   weight:           Float64
/// Container:
///   orientation:      UInt8 (0: horizontal, 1: vertical)
///   layout:           UInt8 (0: tiles, 1: accordion)
///   weight:           Float64
///   childCount:       UInt16
///   children:         Node...
/// ```
extension [TilingTreeSnapshot] {
    func encoded() -> Data {
        var data = Data()
        data.appendLE(UInt16(clamping: count))
        for tree in prefix(Int(UInt16.max)) {
            let name = Data(tree.workspace.utf8).prefix(Int(UInt16.max))
            data.appendLE(UInt16(name.count))
            data.append(name)
            data.appendLE(tree.mostRecentWindow ?? 0)
            tree.root.encode(into: &data)
        }
        return data
    }

    /// nil if the data isn't a trees section (e.g. it's damaged): nothing is restored then
    init?(decoding data: Data) {
        var reader = DataReader(data)
        guard let count = reader.read(UInt16.self) else { return nil }
        var trees: [TilingTreeSnapshot] = []
        for _ in 0 ..< count {
            guard let nameLength = reader.read(UInt16.self),
                  let name = reader.readString(length: Int(nameLength)),
                  let mostRecentWindow = reader.read(UInt32.self),
                  let root = TilingTreeSnapshot.Container(&reader, depth: 0)
            else { return nil }
            trees.append(TilingTreeSnapshot(workspace: name, mostRecentWindow: mostRecentWindow == 0 ? nil : mostRecentWindow, root: root))
        }
        guard reader.isAtEnd else { return nil }
        self = trees
    }
}

extension TilingTreeSnapshot.Container {
    /// Deeper trees aren't made by hand. A damaged file must not overflow the stack
    private static let maxDepth = 64

    fileprivate func encode(into data: inout Data) {
        data.appendLE(UInt8(orientation == .h ? 0 : 1))
        data.appendLE(UInt8(layout == .tiles ? 0 : 1))
        data.appendLE(Double(max(weight, 0)).bitPattern)
        data.appendLE(UInt16(clamping: children.count))
        for child in children.prefix(Int(UInt16.max)) {
            switch child {
                case .window(let id, let weight):
                    data.appendLE(UInt8(0))
                    data.appendLE(id)
                    data.appendLE(Double(max(weight, 0)).bitPattern)
                case .container(let container):
                    data.appendLE(UInt8(1))
                    container.encode(into: &data)
            }
        }
    }

    fileprivate init?(_ reader: inout DataReader, depth: Int) {
        guard depth <= Self.maxDepth,
              let orientation = reader.read(UInt8.self), orientation <= 1,
              let layout = reader.read(UInt8.self), layout <= 1,
              let weight = reader.readWeight(),
              let childCount = reader.read(UInt16.self)
        else { return nil }
        var children: [TilingTreeSnapshot.Node] = []
        for _ in 0 ..< childCount {
            switch reader.read(UInt8.self) {
                case 0:
                    guard let id = reader.read(UInt32.self), let weight = reader.readWeight() else { return nil }
                    children.append(.window(nativeWindowId: id, weight: weight))
                case 1:
                    guard let container = Self(&reader, depth: depth + 1) else { return nil }
                    children.append(.container(container))
                default:
                    return nil
            }
        }
        self.init(orientation: orientation == 0 ? .h : .v, layout: layout == 0 ? .tiles : .accordion, weight: weight, children: children)
    }
}

/// Reads little-endian values from a `Data` (e.g. a memory mapping), with bounds checks
private struct DataReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }

    var isAtEnd: Bool { offset == data.count }

    mutating func read<T: FixedWidthInteger>(_: T.Type) -> T? {
        guard offset + MemoryLayout<T>.size <= data.count else { return nil }
        defer { offset += MemoryLayout<T>.size }
        return data.loadLE(T.self, at: offset)
    }

    /// A weight is a finite number, not negative: anything else would break the layout
    mutating func readWeight() -> CGFloat? {
        guard let bits = read(UInt64.self) else { return nil }
        let weight = Double(bitPattern: bits)
        return weight.isFinite && weight >= 0 ? CGFloat(weight) : nil
    }

    mutating func readString(length: Int) -> String? {
        guard offset + length <= data.count else { return nil }
        defer { offset += length }
        return String(decoding: data[(data.startIndex + offset) ..< (data.startIndex + offset + length)], as: UTF8.self)
    }
}
