@testable import AppBundle
import AppKit
import Common

final class TestWindow: Window, CustomStringConvertible {
    private var _rect: Rect?
    var isMacosFullscreenForTest = false

    @MainActor
    private init(_ id: OpaqueWindowId, _ parent: NonLeafTreeNodeObject, _ adaptiveWeight: CGFloat, _ rect: Rect?) {
        _rect = rect
        super.init(id: id, TestApp.shared, lastFloatingSize: nil, parent: parent, adaptiveWeight: adaptiveWeight, index: INDEX_BIND_LAST)
    }

    @discardableResult
    @MainActor
    static func new(id: OpaqueWindowId, parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat = 1, rect: Rect? = nil) -> TestWindow {
        let wi = TestWindow(id, parent, adaptiveWeight, rect)
        TestApp.shared._windows.append(wi)
        return wi
    }

    nonisolated var description: String { "TestWindow(\(windowId))" }

    /// Emulates the actual frame of the window, e.g. an app that refuses to shrink its window
    func setActualRectForTest(_ rect: Rect?) { _rect = rect }

    @MainActor
    override func nativeFocus() {
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = self
    }

    /// Frames that actually reached the window (unchanged frames are filtered by ``Window/setAxFrame(_:_:)``)
    private(set) var sentFrames: [(topLeft: CGPoint?, size: CGSize?)] = []

    /// Emulates an app: the sent frames are applied to the window, but the window doesn't shrink below `minimumSizeForTest`
    var appliesSentFramesForTest = false
    var minimumSizeForTest: CGSize = .zero

    override func sendAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        sentFrames.append((topLeft, size))
        guard appliesSentFramesForTest else { return }
        let current = _rect ?? Rect(topLeftX: 0, topLeftY: 0, width: 0, height: 0)
        _rect = Rect(
            topLeftX: topLeft?.x ?? current.topLeftX,
            topLeftY: topLeft?.y ?? current.topLeftY,
            width: max(size?.width ?? current.width, minimumSizeForTest.width),
            height: max(size?.height ?? current.height, minimumSizeForTest.height),
        )
    }

    override func closeAxWindow() {
        unbindAsClosed() // The same as MacWindow.garbageCollect
    }

    override func getTitle(_ cm: CancellationMode) async throws -> String { description }

    @MainActor override func getAxRect(_ cm: CancellationMode) async throws -> Rect? { // todo change to not Optional
        _rect
    }

    @MainActor override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? {
        _rect.map { CGSize(width: $0.width, height: $0.height) }
    }

    override func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { isMacosFullscreenForTest }
}

extension OpaqueWindowId: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) { self.init(value) }
}
