import Common

/// The space between the windows (inner) and along the edges of the screen (outer), in points
struct Gaps: Equatable, Sendable {
    var inner: Inner
    var outer: Outer

    static let zero = Gaps(inner: .init(vertical: 0, horizontal: 0), outer: .init(left: 0, bottom: 0, top: 0, right: 0))

    struct Inner: Equatable, Sendable {
        var vertical: Int
        var horizontal: Int

        func get(_ orientation: Orientation) -> Int {
            orientation == .h ? horizontal : vertical
        }
    }

    struct Outer: Equatable, Sendable {
        var left: Int
        var bottom: Int
        var top: Int
        var right: Int
    }
}
