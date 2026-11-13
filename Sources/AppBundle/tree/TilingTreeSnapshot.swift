import AppKit
import Common

/// The tiling tree of a workspace: where every window was in the layout, and how big. Persisted across restarts of
/// MarSpace (``PersistedTilingTree``), and remembered by a workspace for the layouts that it isn't in (see
/// ``WorkspaceLayout``)
struct TilingTreeSnapshot<WindowId: Hashable & Sendable>: Equatable, Sendable {
    let workspace: String
    /// The window that gets the focus when the workspace is shown
    let mostRecentWindow: WindowId?
    let root: Container

    struct Container: Equatable, Sendable {
        let orientation: Orientation
        let layout: Layout
        let weight: CGFloat
        let children: [Node]
    }

    indirect enum Node: Equatable, Sendable {
        case window(id: WindowId, weight: CGFloat)
        /// A floating window that remembers its place in the tree (`pop-out`, `layout floating`, see ``TilingSlot``):
        /// where it comes back to when it's made a tile
        case away(id: WindowId, weight: CGFloat)
        case container(Container)
    }
}

/// The windows are identified by their native window ids, which survive a restart of MarSpace (not a reboot)
typealias PersistedTilingTree = TilingTreeSnapshot<UInt32>

extension Workspace {
    /// The floating windows that remember their places in the tree are in the snapshot at these places (see
    /// ``TilingTreeSnapshot/Node/away(id:weight:)``), also when they came along to another workspace (pinned)
    ///
    /// - Parameter windowId: the id of a window in the snapshot. A window without one is left out
    /// - Returns: nil if the workspace has no tiling windows
    @MainActor
    func tilingTreeSnapshot<WindowId>(windowId: (Window) -> WindowId?) -> TilingTreeSnapshot<WindowId>? {
        let away = AwayWindowPlaces(of: self, windowId)
        guard var root = rootTilingContainer.snapshot(windowId, away) else { return nil }
        if let rewrap = away.rootRewrap {
            let wrapper = TilingTreeSnapshot<WindowId>.Node.container(.init(
                orientation: root.orientation,
                layout: root.layout,
                weight: rewrap.wrapperWeight,
                children: root.children,
            ))
            root = .init(
                orientation: rewrap.orientation,
                layout: rewrap.layout,
                weight: 1,
                children: rewrap.isAfterNeighbor ? [wrapper, rewrap.node] : [rewrap.node, wrapper],
            )
        }
        guard root.containsTilingWindow else { return nil }
        return TilingTreeSnapshot(
            workspace: name,
            mostRecentWindow: rootTilingContainer.mostRecentWindowRecursive.flatMap(windowId),
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
    /// A floating window that lost its place in the tree (a restart of MarSpace) gets it back from the snapshot: made a
    /// tile, it comes back there (see ``TilingTreeSnapshot/Node/away(id:weight:)``). It stays floating where it is
    ///
    /// - Parameter windowId: the id of a window in the snapshot
    @MainActor
    func restoreTilingTree<WindowId>(_ snapshot: TilingTreeSnapshot<WindowId>, windowId: (Window) -> WindowId?) {
        let previousRoot = rootTilingContainer
        let tilingWindows = previousRoot.allLeafWindowsRecursive
        var known: [WindowId: Window] = [:]
        for window in tilingWindows {
            if let id = windowId(window) { known[id] = window }
        }
        guard snapshot.root.contains(anyOf: known) else { return } // Nothing to restore: the tree stays as it is
        var away: [WindowId: Window] = [:]
        for window in Workspace.all.flatMap(\.floatingWindowsIfAny) where window.tilingSlot == nil && !window.isFloatedByWorkspaceLayout {
            if let id = windowId(window) { away[id] = window }
        }

        previousRoot.unbindFromParent() // A workspace has one root. The windows that aren't restored are still in it
        let root = TilingContainer(parent: self, adaptiveWeight: 1, snapshot.root.orientation, snapshot.root.layout, index: INDEX_BIND_LAST)
        var restored: Set<WindowId> = []
        var returning: [ReturningWindow] = []
        root.restoreChildren(of: snapshot.root, known, away, &restored, &returning)
        // In the order of the tree: the windows that left the same container before know where they come back
        for window in returning {
            window.window.leaveTilingTreeRememberingSlot(for: window.floatingContainer, isPinned: window.isPinned)
        }
        snapshot.mostRecentWindow.flatMap { known[$0] }?.markAsMostRecentChild()
        // Opened while MarSpace wasn't running: next to the window that was the most recent one, like any new window
        for window in tilingWindows where windowId(window).map(restored.contains) != true {
            window.bindAsNewTilingWindow(to: self)
        }
    }
}

/// The places in the tiling tree of a workspace where its floating windows come back to (see
/// ``Window/tilingSlotReturn(on:)``), as nodes of the snapshot
@MainActor
private struct AwayWindowPlaces<WindowId: Hashable & Sendable> {
    typealias Node = TilingTreeSnapshot<WindowId>.Node
    struct Wrapper {
        let isAfterNeighbor: Bool
        let orientation: Orientation
        let layout: Layout
        let neighborWeight: CGFloat
        let node: Node
    }
    struct RootRewrap {
        let isAfterNeighbor: Bool
        let orientation: Orientation
        let layout: Layout
        let wrapperWeight: CGFloat
        let node: Node
    }

    /// By container: before its child at the index
    private(set) var children: [ObjectIdentifier: [(index: Int, node: Node)]] = [:]
    /// By neighbor: one window per neighbor
    private(set) var wrappers: [ObjectIdentifier: Wrapper] = [:]
    private(set) var rootRewrap: RootRewrap? = nil

    init(of workspace: Workspace, _ windowId: (Window) -> WindowId?) {
        for window in Workspace.all.flatMap(\.floatingWindowsIfAny) where window.tilingSlot != nil {
            guard let id = windowId(window), let place = window.tilingSlotReturn(on: workspace) else { continue }
            switch place {
                case .child(let parent, let index, let weight):
                    children[ObjectIdentifier(parent), default: []].append((index, .away(id: id, weight: weight)))
                case .wrapping(let neighbor, let isAfterNeighbor, let orientation, let layout, let neighborWeight, let weight):
                    if wrappers[ObjectIdentifier(neighbor)] != nil { continue }
                    wrappers[ObjectIdentifier(neighbor)] =
                        Wrapper(isAfterNeighbor: isAfterNeighbor, orientation: orientation, layout: layout, neighborWeight: neighborWeight, node: .away(id: id, weight: weight))
                case .rewrappingRoot(let isAfterNeighbor, let orientation, let layout, let wrapperWeight, let weight):
                    if rootRewrap != nil { continue }
                    rootRewrap =
                        RootRewrap(isAfterNeighbor: isAfterNeighbor, orientation: orientation, layout: layout, wrapperWeight: wrapperWeight, node: .away(id: id, weight: weight))
            }
        }
        // The other windows would come back to the root before it's wrapped again
        if rootRewrap != nil { children[ObjectIdentifier(workspace.rootTilingContainer)] = nil }
    }
}

/// A floating window that `restoreTilingTree` put back at its place in the tree, to remember it
private struct ReturningWindow {
    let window: Window
    let floatingContainer: FloatingWindowsContainer
    let isPinned: Bool
}

extension TilingContainer {
    @MainActor
    fileprivate func snapshot<WindowId>(_ windowId: (Window) -> WindowId?, _ away: AwayWindowPlaces<WindowId>) -> TilingTreeSnapshot<WindowId>.Container? {
        let orientation = orientation
        let awayChildren = away.children[ObjectIdentifier(self)] ?? []
        var children: [TilingTreeSnapshot<WindowId>.Node] = []
        for (index, child) in self.children.enumerated() {
            children += awayChildren.filter { $0.index == index }.map(\.node)
            let node: TilingTreeSnapshot<WindowId>.Node? = switch child.tilingTreeNodeCasesOrDie() {
                case .window(let window): windowId(window).map { .window(id: $0, weight: child.getWeight(orientation)) }
                case .tilingContainer(let container): container.snapshot(windowId, away).map { .container($0) }
            }
            guard let node else { continue }
            if let wrapper = away.wrappers[ObjectIdentifier(child)] {
                let neighbor = node.withWeight(wrapper.neighborWeight)
                children.append(.container(.init(
                    orientation: wrapper.orientation,
                    layout: wrapper.layout,
                    weight: child.getWeight(orientation),
                    children: wrapper.isAfterNeighbor ? [neighbor, wrapper.node] : [wrapper.node, neighbor],
                )))
            } else {
                children.append(node)
            }
        }
        children += awayChildren.filter { $0.index >= self.children.count }.map(\.node)
        if children.isEmpty { return nil }
        let weight = (parent as? TilingContainer).map { getWeight($0.orientation) } ?? 1
        return TilingTreeSnapshot<WindowId>.Container(orientation: orientation, layout: layout, weight: weight, children: children)
    }

    @MainActor
    fileprivate func restoreChildren<WindowId>(
        of snapshot: TilingTreeSnapshot<WindowId>.Container,
        _ known: [WindowId: Window],
        _ away: [WindowId: Window],
        _ restored: inout Set<WindowId>,
        _ returning: inout [ReturningWindow],
    ) {
        for child in snapshot.children {
            switch child {
                case .window(let id, let weight):
                    // The same id twice (a damaged file): the window is where it was put first
                    guard let window = known[id], restored.insert(id).inserted else { continue }
                    window.dwindleSplitAnchor = nil // Of the placement as a new window, which the restored tree replaces
                    window.bind(to: self, adaptiveWeight: weight, index: INDEX_BIND_LAST)
                case .away(let id, let weight):
                    if let window = known[id] { // A tile again: there
                        guard restored.insert(id).inserted else { continue }
                        window.dwindleSplitAnchor = nil
                        window.bind(to: self, adaptiveWeight: weight, index: INDEX_BIND_LAST)
                    } else if let window = away[id], let floatingContainer = window.parent as? FloatingWindowsContainer,
                              restored.insert(id).inserted
                    {
                        returning.append(ReturningWindow(window: window, floatingContainer: floatingContainer, isPinned: window.isPinned))
                        window.bind(to: self, adaptiveWeight: weight, index: INDEX_BIND_LAST)
                    }
                case .container(let container):
                    guard container.contains(anyOf: known) else { continue }
                    TilingContainer(parent: self, adaptiveWeight: container.weight, container.orientation, container.layout, index: INDEX_BIND_LAST)
                        .restoreChildren(of: container, known, away, &restored, &returning)
            }
        }
    }
}

extension TilingTreeSnapshot.Container {
    fileprivate func contains(anyOf known: [WindowId: Window]) -> Bool {
        children.contains { child in
            switch child {
                case .window(let id, _), .away(let id, _): known[id] != nil
                case .container(let container): container.contains(anyOf: known)
            }
        }
    }

    /// Not only floating windows
    fileprivate var containsTilingWindow: Bool {
        children.contains { child in
            switch child {
                case .window: true
                case .away: false
                case .container(let container): container.containsTilingWindow
            }
        }
    }
}

extension TilingTreeSnapshot.Node {
    fileprivate func withWeight(_ weight: CGFloat) -> Self {
        switch self {
            case .window(let id, _): .window(id: id, weight: weight)
            case .away(let id, _): .away(id: id, weight: weight)
            case .container(let container):
                .container(.init(orientation: container.orientation, layout: container.layout, weight: weight, children: container.children))
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
///   kind:             UInt8 (0: window, 1: container, 2: floating window that remembers its place: an away window)
/// Window, away window:
///   nativeWindowId:   UInt32
///   weight:           Float64
/// Container:
///   orientation:      UInt8 (0: horizontal, 1: vertical)
///   layout:           UInt8 (0: tiles, 1: accordion, 2: scrolling)
///   weight:           Float64
///   childCount:       UInt16
///   children:         Node...
/// ```
extension [PersistedTilingTree] {
    func encoded() -> Data {
        var data = Data()
        data.appendLE(UInt16(clamping: count))
        for tree in prefix(Int(UInt16.max)) { tree.encode(into: &data) }
        return data
    }

    /// nil if the data isn't a trees section (e.g. it's damaged): nothing is restored then
    init?(decoding data: Data) {
        var reader = DataReader(data)
        guard let count = reader.read(UInt16.self) else { return nil }
        var trees: [PersistedTilingTree] = []
        for _ in 0 ..< count {
            guard let tree = PersistedTilingTree(&reader) else { return nil }
            trees.append(tree)
        }
        guard reader.isAtEnd else { return nil }
        self = trees
    }
}

extension PersistedTilingTree {
    fileprivate func encode(into data: inout Data) {
        let name = Data(workspace.utf8).prefix(Int(UInt16.max))
        data.appendLE(UInt16(name.count))
        data.append(name)
        data.appendLE(mostRecentWindow ?? 0)
        root.encode(into: &data)
    }

    fileprivate init?(_ reader: inout DataReader) {
        guard let nameLength = reader.read(UInt16.self),
              let name = reader.readString(length: Int(nameLength)),
              let mostRecentWindow = reader.read(UInt32.self),
              let root = TilingTreeSnapshot.Container(&reader, depth: 0)
        else { return nil }
        self.init(workspace: name, mostRecentWindow: mostRecentWindow == 0 ? nil : mostRecentWindow, root: root)
    }
}

extension TilingTreeSnapshot {
    /// The same tree with other window ids: the windows without one are left out, and the containers that are empty
    /// then. nil if no window is left
    func mapWindowIds<Other>(_ transform: (WindowId) -> Other?) -> TilingTreeSnapshot<Other>? {
        guard let root = root.mapWindowIds(transform) else { return nil }
        return TilingTreeSnapshot<Other>(workspace: workspace, mostRecentWindow: mostRecentWindow.flatMap(transform), root: root)
    }
}

extension TilingTreeSnapshot.Container {
    fileprivate func mapWindowIds<Other>(_ transform: (WindowId) -> Other?) -> TilingTreeSnapshot<Other>.Container? {
        let children: [TilingTreeSnapshot<Other>.Node] = children.compactMap { child in
            switch child {
                case .window(let id, let weight): transform(id).map { .window(id: $0, weight: weight) }
                case .away(let id, let weight): transform(id).map { .away(id: $0, weight: weight) }
                case .container(let container): container.mapWindowIds(transform).map { .container($0) }
            }
        }
        return children.isEmpty ? nil : .init(orientation: orientation, layout: layout, weight: weight, children: children)
    }
}

/// The layout that `workspace-layout` gave a workspace, and the trees that it remembers (see ``WorkspaceLayoutMemory``),
/// persisted across restarts of MarSpace with native window ids
struct WorkspaceLayoutRecord: Equatable, Sendable {
    let workspace: String
    let chosen: WorkspaceLayout?
    /// Of the layouts that the workspace isn't in: tiling, scrolling
    let trees: [WorkspaceLayout: PersistedTilingTree]
}

/// The workspace layouts section of the window placement file (little-endian):
/// ```
/// workspaceCount: UInt16
/// Per workspace:
///   nameLength:   UInt16
///   name:         UTF-8
///   chosen:       UInt8 (0: none, 1: tiling, 2: scrolling, 3: floating)
///   treeCount:    UInt8
///   Per tree:
///     layout:     UInt8 (1: tiling, 2: scrolling)
///     tree:       a tree of the trees section
/// ```
extension [WorkspaceLayoutRecord] {
    func encoded() -> Data {
        var data = Data()
        data.appendLE(UInt16(clamping: count))
        for record in prefix(Int(UInt16.max)) {
            let name = Data(record.workspace.utf8).prefix(Int(UInt16.max))
            data.appendLE(UInt16(name.count))
            data.append(name)
            data.appendLE(record.chosen?.byte ?? 0)
            let trees = record.trees.sorted { $0.key.byte < $1.key.byte }
            data.appendLE(UInt8(trees.count))
            for (layout, tree) in trees {
                data.appendLE(layout.byte)
                tree.encode(into: &data)
            }
        }
        return data
    }

    /// nil if the data isn't a workspace layouts section (e.g. it's damaged)
    init?(decoding data: Data) {
        var reader = DataReader(data)
        guard let count = reader.read(UInt16.self) else { return nil }
        var records: [WorkspaceLayoutRecord] = []
        for _ in 0 ..< count {
            guard let nameLength = reader.read(UInt16.self),
                  let name = reader.readString(length: Int(nameLength)),
                  let chosenByte = reader.read(UInt8.self),
                  let treeCount = reader.read(UInt8.self)
            else { return nil }
            let chosen = WorkspaceLayout(byte: chosenByte)
            guard chosenByte == 0 || chosen != nil else { return nil }
            var trees: [WorkspaceLayout: PersistedTilingTree] = [:]
            for _ in 0 ..< treeCount {
                guard let layout = reader.read(UInt8.self).flatMap(WorkspaceLayout.init(byte:)), layout != .floating,
                      let tree = PersistedTilingTree(&reader)
                else { return nil }
                trees[layout] = tree
            }
            records.append(WorkspaceLayoutRecord(workspace: name, chosen: chosen, trees: trees))
        }
        guard reader.isAtEnd else { return nil }
        self = records
    }
}

extension WorkspaceLayout {
    fileprivate var byte: UInt8 {
        switch self {
            case .tiling: 1
            case .scrolling: 2
            case .floating: 3
        }
    }

    fileprivate init?(byte: UInt8) {
        switch byte {
            case 1: self = .tiling
            case 2: self = .scrolling
            case 3: self = .floating
            default: return nil
        }
    }
}

extension PersistedTilingTree.Container {
    /// Deeper trees aren't made by hand. A damaged file must not overflow the stack
    private static let maxDepth = 64

    fileprivate func encode(into data: inout Data) {
        data.appendLE(UInt8(orientation == .h ? 0 : 1))
        data.appendLE(layout.byte)
        data.appendLE(Double(max(weight, 0)).bitPattern)
        data.appendLE(UInt16(clamping: children.count))
        for child in children.prefix(Int(UInt16.max)) {
            switch child {
                case .window(let id, let weight):
                    data.appendLE(UInt8(0))
                    data.appendLE(id)
                    data.appendLE(Double(max(weight, 0)).bitPattern)
                case .away(let id, let weight):
                    data.appendLE(UInt8(2))
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
              let layout = reader.read(UInt8.self).flatMap(Layout.init(byte:)),
              let weight = reader.readWeight(),
              let childCount = reader.read(UInt16.self)
        else { return nil }
        var children: [PersistedTilingTree.Node] = []
        for _ in 0 ..< childCount {
            switch reader.read(UInt8.self) {
                case 0:
                    guard let id = reader.read(UInt32.self), let weight = reader.readWeight() else { return nil }
                    children.append(.window(id: id, weight: weight))
                case 1:
                    guard let container = Self(&reader, depth: depth + 1) else { return nil }
                    children.append(.container(container))
                case 2:
                    guard let id = reader.read(UInt32.self), let weight = reader.readWeight() else { return nil }
                    children.append(.away(id: id, weight: weight))
                default:
                    return nil
            }
        }
        self.init(orientation: orientation == 0 ? .h : .v, layout: layout, weight: weight, children: children)
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

extension Layout {
    fileprivate var byte: UInt8 {
        switch self {
            case .tiles: 0
            case .accordion: 1
            case .scrolling: 2
        }
    }

    fileprivate init?(byte: UInt8) {
        switch byte {
            case 0: self = .tiles
            case 1: self = .accordion
            case 2: self = .scrolling
            default: return nil
        }
    }
}
