@testable import AppBundle
import Common
import CoreGraphics
import Testing

// The test monitor is 1920x1080 (the layout height is 1079), no gaps
@MainActor
@Suite(.serializedGlobally)
struct MinimumSizeTest {
    init() { setUpWorkspacesForTests() }

    @Test func testFitLengthsWithoutMinimumsIsTheClassicLayout() {
        assertEquals(fitLengths(weights: [1, 1], minimums: [], total: 1920), [960, 960])
        assertEquals(fitLengths(weights: [500, 1000], minimums: [0, 0], total: 1920), [710, 1210])
        // Negative lengths are possible in the classic layout. They are kept as is
        assertEquals(fitLengths(weights: [3000, 10], minimums: [], total: 1920), [2455, -535])
        assertEquals(fitLengths(weights: [], minimums: [], total: 1920), [])
    }

    @Test func testFitLengthsGivesAtLeastTheMinimum() {
        assertEquals(fitLengths(weights: [1, 1], minimums: [1200, 0], total: 1920), [1200, 720])
        assertEquals(fitLengths(weights: [1, 1, 1], minimums: [0, 1000, 0], total: 1920), [460, 1000, 460])
        // The window that would be too small gets exactly its minimum, the other window gets the rest
        assertEquals(fitLengths(weights: [1, 1], minimums: [1000, 900], total: 1920), [1000, 920])
    }

    @Test func testFitLengthsReturnsNilWhenMinimumsDontFit() {
        assertNil(fitLengths(weights: [1, 1], minimums: [1000, 960], total: 1920))
    }

    @Test func testLayoutRespectsMinimumSize() async throws {
        let workspace = Workspace.get(byName: name)
        var windows: [TestWindow] = []
        workspace.rootTilingContainer.apply {
            windows.append(TestWindow.new(id: 1, parent: $0))
            windows.append(TestWindow.new(id: 2, parent: $0))
        }
        windows[0].learnedMinimumSize = CGSize(width: 1200, height: 0)

        try await workspace.layoutWorkspace()
        assertEquals(windows.map { $0.sentFrames.last?.size }, [CGSize(width: 1200, height: 1079), CGSize(width: 720, height: 1079)])
        assertEquals(windows.map { $0.sentFrames.last?.topLeft }, [CGPoint(x: 0, y: 0), CGPoint(x: 1200, y: 0)])
    }

    @Test func testWindowsThatDontFitAreStackedAsAccordion() async throws {
        let workspace = Workspace.get(byName: name)
        var windows: [TestWindow] = []
        let root = workspace.rootTilingContainer.apply {
            windows.append(TestWindow.new(id: 1, parent: $0))
            windows.append(TestWindow.new(id: 2, parent: $0))
        }
        // E.g. App Store and GitHub Desktop on a 1800pt wide screen
        windows[0].learnedMinimumSize = CGSize(width: 1000, height: 500)
        windows[1].learnedMinimumSize = CGSize(width: 960, height: 660)

        try await workspace.layoutWorkspace()
        let padding = CGFloat(config.accordionPadding)
        assertEquals(windows.map { $0.sentFrames.last?.size }, [CGSize(width: 1920 - padding, height: 1079), CGSize(width: 1920 - padding, height: 1079)])
        // Rendering only. The tree isn't changed
        assertEquals(root.layoutDescription, .h_tiles([.window(1), .window(2)]))

        // The windows fit again
        windows[1].learnedMinimumSize = .zero
        try await workspace.layoutWorkspace()
        assertEquals(windows.map { $0.sentFrames.last?.size?.width }, [1000, 920])
    }

    @Test func testLearningRequiresTwoObservations() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        let requested = try #require(window.lastAppliedLayoutPhysicalRect)
        assertEquals(requested.width, 960)

        // The app snaps its size to a grid. It isn't a minimum
        window.setActualRectForTest(requested.with(\.width, 965))
        assertEquals(await window.observeSize(), .fits)

        // The app refuses the size
        window.setActualRectForTest(requested.with(\.width, 1000))
        assertEquals(await window.observeSize(), .pending)
        assertEquals(window.learnedMinimumSize, .zero)
        assertEquals(await window.observeSize(), .learned)
        assertEquals(window.learnedMinimumSize, CGSize(width: 1000, height: 0))
    }

    @Test func testTransientResizeIsNotLearned() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        let requested = try #require(window.lastAppliedLayoutPhysicalRect)

        // E.g. an animation or a late frame of an asynchronous app
        window.setActualRectForTest(requested.with(\.width, 1500))
        assertEquals(await window.observeSize(), .pending)
        window.setActualRectForTest(requested)
        assertEquals(await window.observeSize(), .fits)
        assertEquals(window.learnedMinimumSize, .zero)
    }
}
