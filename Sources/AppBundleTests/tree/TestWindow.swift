@testable import AppBundle
import AppKit
import Common

final class TestWindow: Window, CustomStringConvertible {
    /// What the accessibility API reports as the frame of the window
    var axRectForTest: Rect?
    private(set) var axRectReadCount = 0
    /// Runs at the await point of the next frame read
    var onAxRectReadForTest: (@MainActor () -> Void)? = nil
    var isMacosFullscreenForTest = false

    @MainActor
    private init(_ id: OpaqueWindowId, _ parent: NonLeafTreeNodeObject, _ adaptiveWeight: CGFloat, _ rect: Rect?) {
        axRectForTest = rect
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


    @MainActor
    override func nativeFocus() {
        appForTests = TestApp.shared
        TestApp.shared.focusedWindow = self
    }

    /// Frames that actually reached the window (unchanged frames are filtered by ``Window/setAxFrame(_:_:)``)
    private(set) var sentFrames: [(topLeft: CGPoint?, size: CGSize?)] = []

    override func sendAxFrame(_ topLeft: CGPoint?, _ size: CGSize?) {
        sentFrames.append((topLeft, size))
    }

    override func closeAxWindow() {
        unbindAsClosed() // The same as MacWindow.garbageCollect
    }

    override func getTitle(_ cm: CancellationMode) async throws -> String { description }

    @MainActor override func getAxRect(_ cm: CancellationMode) async throws -> Rect? { // todo change to not Optional
        axRectReadCount += 1
        if let hook = onAxRectReadForTest {
            onAxRectReadForTest = nil
            hook()
        }
        return axRectForTest
    }

    @MainActor override func getAxSize(_ cm: CancellationMode) async throws -> CGSize? {
        axRectForTest.map { CGSize(width: $0.width, height: $0.height) }
    }

    /// Runs at the await point of the next native state read (e.g. a notification arrives, or the session is canceled)
    var onNativeStateReadForTest: (@MainActor () throws -> Void)? = nil

    @MainActor override func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool {
        if let hook = onNativeStateReadForTest {
            onNativeStateReadForTest = nil
            try hook()
        }
        return isMacosFullscreenForTest
    }
}

extension OpaqueWindowId: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) { self.init(value) }
}
