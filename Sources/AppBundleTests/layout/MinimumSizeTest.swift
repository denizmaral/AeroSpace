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

    /// Window 1 emulates an app that applies the sent frames, window 2 is a regular window
    private func twoWindows(_ workspace: Workspace, minimumSize: CGSize = .zero) async throws -> (TestWindow, TestWindow) {
        #expect(workspace.focusWorkspace()) // Only windows of visible workspaces are checked
        let window1 = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        window1.appliesSentFramesForTest = true
        window1.minimumSizeForTest = minimumSize
        let window2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace()
        return (window1, window2)
    }

    @Test func testRefusedSizeIsLearned() async throws {
        let (window, _) = try await twoWindows(Workspace.get(byName: name), minimumSize: CGSize(width: 1000, height: 0))
        assertEquals(window.lastAppliedLayoutPhysicalRect?.width, 960) // The window stays 1000 wide

        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), true)
        assertEquals(window.effectiveMinimumSize, CGSize(width: 1000, height: 0))
    }

    @Test func testGridSnappingIsNotAMinimum() async throws {
        let (window, _) = try await twoWindows(Workspace.get(byName: name), minimumSize: CGSize(width: 965, height: 0))
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), false)
        assertEquals(window.effectiveMinimumSize, .zero)
    }

    /// E.g. an animation, a late frame of an asynchronous app or a resize initiated by the app itself.
    /// The check sends the requested frame again, the app accepts it
    @Test func testTransientResizeIsNotLearned() async throws {
        let (window, _) = try await twoWindows(Workspace.get(byName: name))
        window.setActualRectForTest(try #require(window.lastAppliedLayoutPhysicalRect).with(\.width, 1500))
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), false)
        assertEquals(window.effectiveMinimumSize, .zero)
    }

    /// Windows of invisible workspaces are hidden in the corner, only their position is sent
    @Test func testWindowOfInvisibleWorkspaceIsNotChecked() async throws {
        let workspace = Workspace.get(byName: "A")
        #expect(workspace.focusWorkspace())
        let (window, window2) = try await twoWindows(workspace)
        #expect(Workspace.get(byName: "B").focusWorkspace())
        window.setActualRectForTest(try #require(window.lastAppliedLayoutPhysicalRect).with(\.width, 1500))
        let sentFramesCount = window.sentFrames.count
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), false)
        assertEquals(window.sentFrames.count, sentFramesCount) // The window must stay hidden in the corner

        #expect(workspace.focusWorkspace())
        try await workspace.layoutWorkspace()
        assertEquals([window, window2].map { $0.sentFrames.last?.size?.width }, [960, 960])
    }

    /// A burst of resized notifications must not shortcut the confirmation
    @Test func testBurstOfNotificationsDoesntShortcutTheCheck() async throws {
        let (window, _) = try await twoWindows(Workspace.get(byName: name))
        window.setActualRectForTest(try #require(window.lastAppliedLayoutPhysicalRect).with(\.width, 1500))
        window.scheduleMinimumSizeCheck()
        try await Task.sleep(for: .milliseconds(20))
        window.scheduleMinimumSizeCheck()
        try await Task.sleep(for: .milliseconds(20))
        assertEquals(window.effectiveMinimumSize, .zero)
        try await Task.sleep(for: .milliseconds(600))
        assertEquals(window.effectiveMinimumSize, .zero) // The app accepted the frame that was sent again
    }

    @Test func testMinimumIsForgottenOnAnotherWorkspace() async throws {
        let (window, _) = try await twoWindows(Workspace.get(byName: name), minimumSize: CGSize(width: 1000, height: 0))
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), true)

        window.bind(to: Workspace.get(byName: "other").rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        assertEquals(window.effectiveMinimumSize, .zero)
    }

    @Test func testMinimumIsForgottenWhenTheWindowIsSmaller() async throws {
        let workspace = Workspace.get(byName: name)
        let (window, _) = try await twoWindows(workspace, minimumSize: CGSize(width: 1300, height: 0))
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), true)
        assertEquals(window.effectiveMinimumSize.width, 1300)

        // E.g. the app hides its sidebar and shrinks the window
        window.minimumSizeForTest = .zero
        window.setActualRectForTest(try #require(window.lastAppliedLayoutPhysicalRect).with(\.width, 900))
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), false)
        assertEquals(window.effectiveMinimumSize, .zero)
    }

    /// The accordion fallback is rendering only. Hit testing (focus-follows-mouse, drag & drop) must see the accordion
    @Test func testHitTestingInAccordionFallback() async throws {
        let workspace = Workspace.get(byName: name)
        var windows: [TestWindow] = []
        let root = workspace.rootTilingContainer.apply {
            windows.append(TestWindow.new(id: 1, parent: $0))
            windows.append(TestWindow.new(id: 2, parent: $0))
        }
        windows[0].learnedMinimumSize = CGSize(width: 1000, height: 0)
        windows[1].learnedMinimumSize = CGSize(width: 960, height: 0)
        #expect(windows[1].focusWindow())
        try await workspace.layoutWorkspace()

        let hit = CGPoint(x: 960, y: 500).findWindowRecursively(in: root, virtual: false, fullscreenCoversAll: false)
        #expect(hit === windows[1])
    }
}
