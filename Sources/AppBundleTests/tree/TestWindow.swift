@testable import AppBundle
import AppKit
import Common

final class TestWindow: Window, CustomStringConvertible {
    /// What the accessibility API reports as the frame of the window. A sent frame changes it like an app does
    var axRectForTest: Rect?
    /// The app refuses a smaller size, e.g. App Store is at least 1000 wide
    var minimumSizeForTest: CGSize? = nil
    /// The frames read back after sends, delivered by ``deliverReadBacksForTest()``. nil: delivered right away
    var heldReadBacksForTest: [(frame: Rect, generation: UInt)]? = nil
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

    /// Frames that actually reached the window (unchanged frames are filtered by ``Window/setAxFrame(_:_:readBack:)``)
    private(set) var sentFrames: [(topLeft: CGPoint?, size: CGSize?)] = []

    override func sendAxFrame(_ topLeft: CGPoint?, _ size: CGSize?, readBack: UInt?) {
        sentFrames.append((topLeft, size))
        let origin = topLeft ?? axRectForTest?.topLeftCorner ?? .zero
        var applied = size ?? axRectForTest?.size ?? .zero
        if let minimum = minimumSizeForTest {
            applied = CGSize(width: max(applied.width, minimum.width), height: max(applied.height, minimum.height))
        }
        let frame = Rect(topLeftX: origin.x, topLeftY: origin.y, width: applied.width, height: applied.height)
        axRectForTest = frame
        guard let readBack else { return }
        if heldReadBacksForTest != nil {
            heldReadBacksForTest?.append((frame, readBack))
        } else {
            frameWasReadBack(frame, generation: readBack)
        }
    }

    @MainActor
    func deliverReadBacksForTest() {
        let readBacks = heldReadBacksForTest ?? []
        heldReadBacksForTest = []
        for (frame, generation) in readBacks { frameWasReadBack(frame, generation: generation) }
    }

    override func closeAxWindow() {
        unbindAsClosed() // The same as MacWindow.garbageCollect
    }

    /// The title is an accessibility round trip to the app
    private(set) var titleReadsForTest = 0

    override func getTitle(_ cm: CancellationMode) async throws -> String {
        titleReadsForTest += 1
        return description
    }

    @MainActor override func getAxRect(_ cm: CancellationMode) async throws -> Rect? { // todo change to not Optional
        axRectForTest
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
