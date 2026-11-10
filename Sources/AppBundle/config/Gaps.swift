import Common

struct Gaps: Withable, Equatable, Sendable {
    var inner: Inner
    var outer: Outer

    static let zero = Gaps(inner: .zero, outer: .zero)

    struct Inner: Withable, Equatable, Sendable {
        var vertical: DynamicConfigValue<Int>
        var horizontal: DynamicConfigValue<Int>

        static let zero = Inner(vertical: 0, horizontal: 0)

        init(vertical: Int, horizontal: Int) {
            self.vertical = .constant(vertical)
            self.horizontal = .constant(horizontal)
        }
    }

    struct Outer: Withable, Equatable, Sendable {
        var left: DynamicConfigValue<Int>
        var bottom: DynamicConfigValue<Int>
        var top: DynamicConfigValue<Int>
        var right: DynamicConfigValue<Int>

        static let zero = Outer(left: 0, bottom: 0, top: 0, right: 0)

        init(left: Int, bottom: Int, top: Int, right: Int) {
            self.left = .constant(left)
            self.bottom = .constant(bottom)
            self.top = .constant(top)
            self.right = .constant(right)
        }
    }
}

struct ResolvedGaps {
    let inner: Inner
    let outer: Outer

    struct Inner {
        let vertical: Int
        let horizontal: Int

        func get(_ orientation: Orientation) -> Int {
            orientation == .h ? horizontal : vertical
        }
    }

    struct Outer {
        let left: Int
        let bottom: Int
        let top: Int
        let right: Int
    }

    @MainActor init(gaps: Gaps, monitor: any MonitorInfo) {
        inner = .init(
            vertical: gaps.inner.vertical.getValue(for: monitor),
            horizontal: gaps.inner.horizontal.getValue(for: monitor),
        )

        outer = .init(
            left: gaps.outer.left.getValue(for: monitor),
            bottom: gaps.outer.bottom.getValue(for: monitor),
            top: gaps.outer.top.getValue(for: monitor),
            right: gaps.outer.right.getValue(for: monitor),
        )
    }
}
