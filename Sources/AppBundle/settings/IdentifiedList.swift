import Foundation

/// A list whose elements keep an id for as long as they are in it. The settings window binds, edits, removes and undoes by
/// id, never by index: an index points to another element, or past the end, once a row was removed while its popover was
/// still open (dev-docs/settings-architecture.md).
///
/// The ids exist only in memory: the list is stored as a plain array, and two lists with the same elements are equal
struct IdentifiedList<Element: Sendable>: Sendable {
    typealias ID = UUID

    /// In the order of the elements
    private(set) var ids: [ID]
    private var elements: [Element]

    init(_ elements: [Element]) {
        self.elements = elements
        ids = elements.map { _ in ID() }
    }

    func index(of id: ID) -> Int? { ids.firstIndex(of: id) }

    /// nil: no element has this id (anymore). Setting nil removes the element
    subscript(id id: ID) -> Element? {
        get { index(of: id).map { elements[$0] } }
        set {
            guard let index = index(of: id) else { return }
            if let newValue { elements[index] = newValue } else { remove(at: index) }
        }
    }

    /// The id of the element that was appended last (e.g. to open its editor)
    var lastId: ID? { ids.last }

    /// Like SwiftUI's `onMove`: the ids move with their elements
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var pairs = Array(zip(ids, elements))
        pairs.move(fromOffsets: source, toOffset: destination)
        ids = pairs.map(\.0)
        elements = pairs.map(\.1)
    }

    /// The ids move with their elements (the sort of the standard library writes the elements back by position)
    mutating func sort(by areInIncreasingOrder: (Element, Element) throws -> Bool) rethrows {
        var pairs = Array(zip(ids, elements))
        try pairs.sort { try areInIncreasingOrder($0.1, $1.1) }
        ids = pairs.map(\.0)
        elements = pairs.map(\.1)
    }

    /// The elements that stay keep their ids
    mutating func removeAll(where shouldBeRemoved: (Element) throws -> Bool) rethrows {
        var keptIds: [ID] = []
        var keptElements: [Element] = []
        for (id, element) in zip(ids, elements) where try !shouldBeRemoved(element) {
            keptIds.append(id)
            keptElements.append(element)
        }
        ids = keptIds
        elements = keptElements
    }
}

extension IdentifiedList: RandomAccessCollection, MutableCollection, RangeReplaceableCollection {
    var startIndex: Int { elements.startIndex }
    var endIndex: Int { elements.endIndex }

    /// An element changed in place keeps its id
    subscript(position: Int) -> Element {
        get { elements[position] }
        set { elements[position] = newValue }
    }

    init() { self.init([]) }

    /// New elements get new ids
    mutating func replaceSubrange<C: Collection>(_ subrange: Range<Int>, with newElements: C) where C.Element == Element {
        elements.replaceSubrange(subrange, with: newElements)
        ids.replaceSubrange(subrange, with: newElements.map { _ in ID() })
    }

    /// Sorting and other reorderings swap the ids with their elements
    mutating func swapAt(_ i: Int, _ j: Int) {
        elements.swapAt(i, j)
        ids.swapAt(i, j)
    }
}

extension IdentifiedList: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: Element...) { self.init(elements) }
}

extension IdentifiedList: Equatable where Element: Equatable {
    /// The ids don't count: they only exist while the settings are edited
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.elements == rhs.elements }
}

extension IdentifiedList: Codable where Element: Codable {
    /// A plain array
    init(from decoder: any Decoder) throws { self.init(try [Element](from: decoder)) }

    func encode(to encoder: any Encoder) throws { try elements.encode(to: encoder) }
}

extension IdentifiedList where Element: Comparable {
    mutating func sort() { sort(by: <) }
}
