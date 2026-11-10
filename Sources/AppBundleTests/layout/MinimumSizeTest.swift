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

        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), .learned)
        assertEquals(window.effectiveMinimumSize, CGSize(width: 1000, height: 0))
    }

    @Test func testGridSnappingIsNotAMinimum() async throws {
        let (window, _) = try await twoWindows(Workspace.get(byName: name), minimumSize: CGSize(width: 965, height: 0))
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), .fits)
        assertEquals(window.effectiveMinimumSize, .zero)
    }

    /// E.g. an animation, a late frame of an asynchronous app or a resize initiated by the app itself.
    /// The check sends the requested frame again, the app accepts it
    @Test func testTransientResizeIsNotLearned() async throws {
        let (window, _) = try await twoWindows(Workspace.get(byName: name))
        window.setActualRectForTest(try #require(window.lastAppliedLayoutPhysicalRect).with(\.width, 1500))
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), .fits)
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
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), .fits)
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
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), .learned)

        let workspace = try #require(window.nodeWorkspace)
        window.bind(to: Workspace.get(byName: "other").rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        assertEquals(window.effectiveMinimumSize, .zero)
        // Forgotten, not just masked
        window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        assertEquals(window.effectiveMinimumSize, .zero)
    }

    @Test func testMinimumIsForgottenWhenTheWindowIsSmaller() async throws {
        let workspace = Workspace.get(byName: name)
        let (window, _) = try await twoWindows(workspace, minimumSize: CGSize(width: 1300, height: 0))
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), .learned)
        assertEquals(window.effectiveMinimumSize.width, 1300)

        // E.g. the app hides its sidebar and shrinks the window
        window.minimumSizeForTest = .zero
        window.setActualRectForTest(try #require(window.lastAppliedLayoutPhysicalRect).with(\.width, 900))
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), .fits)
        assertEquals(window.effectiveMinimumSize, .zero)
    }

    /// A nested accordion takes the padding from its windows: the container needs the minimum plus the padding
    @Test func testAccordionPaddingIsPartOfTheMinimum() async throws {
        let workspace = Workspace.get(byName: name)
        var window: TestWindow!
        workspace.rootTilingContainer.apply {
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TilingContainer(parent: $0, adaptiveWeight: 1, .h, .accordion, index: INDEX_BIND_LAST).apply {
                    window = TestWindow.new(id: 1, parent: $0)
                    TestWindow.new(id: 2, parent: $0)
                }
                TestWindow.new(id: 3, parent: $0)
            }
            TestWindow.new(id: 4, parent: $0)
        }
        window.learnedMinimumSize = CGSize(width: 1300, height: 0)
        #expect(window.focusWindow())
        try await workspace.layoutWorkspace()
        assertEquals(window.lastAppliedLayoutPhysicalRect?.width, 1300)
    }

    /// The inner gaps of a nested tiles container are taken from its windows too
    @Test func testInnerGapsArePartOfTheMinimum() async throws {
        config.gaps = Gaps(inner: .init(vertical: 10, horizontal: 10), outer: .zero)
        let workspace = Workspace.get(byName: name)
        var windows: [TestWindow] = []
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                windows.append(TestWindow.new(id: 2, parent: $0))
                windows.append(TestWindow.new(id: 3, parent: $0))
            }
        }
        for window in windows { window.learnedMinimumSize = CGSize(width: 700, height: 0) }
        try await workspace.layoutWorkspace()
        assertEquals(windows.map { $0.lastAppliedLayoutPhysicalRect?.width }, [700, 700])
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

/// Regressions found by the adversarial QA review
@MainActor
@Suite(.serializedGlobally)
struct MinimumSizeCheckRaceTest {
    init() { setUpWorkspacesForTests() }

    private func appWindow(_ workspace: Workspace, minimumWidth: CGFloat) -> TestWindow {
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
        window.appliesSentFramesForTest = true
        window.minimumSizeForTest = CGSize(width: minimumWidth, height: 0)
        return window
    }

    /// The layout changes during the confirmation and the window keeps refusing without changing its size (no new
    /// kAXResizedNotification). The check must not give up
    @Test func testLayoutChangeDuringTheCheck() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        let window = appWindow(workspace, minimumWidth: 700)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
        TestWindow.new(id: 3, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace() // 640: the window stays 700
        window.scheduleMinimumSizeCheck()
        try await Task.sleep(for: .milliseconds(100))
        TestWindow.new(id: 4, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace() // 480: the window stays 700
        try await Task.sleep(for: .milliseconds(1500))
        assertEquals(window.effectiveMinimumSize.width, 700)
    }

    /// Notifications that arrive during a running check must not be lost
    @Test func testNotificationsDuringTheCheck() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        let window = appWindow(workspace, minimumWidth: 700)
        let window2 = TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
        let window3 = TestWindow.new(id: 3, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace() // 640: the window stays 700
        window.scheduleMinimumSizeCheck()
        try await Task.sleep(for: .milliseconds(50))
        window2.unbindFromParent()
        window3.unbindFromParent()
        try await workspace.layoutWorkspace() // 1920: fits
        window.scheduleMinimumSizeCheck()
        try await Task.sleep(for: .milliseconds(50))
        for id: OpaqueWindowId in [5, 6, 7] { TestWindow.new(id: id, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO) }
        try await workspace.layoutWorkspace() // 480: the window stays 700
        window.scheduleMinimumSizeCheck()
        try await Task.sleep(for: .milliseconds(2000))
        assertEquals(window.effectiveMinimumSize.width, 700)
        #expect(window.minimumSizeCheckTask == nil)
    }

    /// The workspace becomes invisible during the AX read. The check must not pull the window out of the corner
    @Test func testCheckDoesntUnhideWindowOfInvisibleWorkspace() async throws {
        let workspace = Workspace.get(byName: "A")
        #expect(workspace.focusWorkspace())
        let window = appWindow(workspace, minimumWidth: 1000)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await workspace.layoutWorkspace() // 960, the window stays 1000
        let corner = CGPoint(x: 1919, y: 1079)
        window.onGetAxSizeForTest = {
            #expect(Workspace.get(byName: "B").focusWorkspace())
            window.setAxFrame(corner, nil) // hideInCorner
        }
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), .fits)
        assertEquals(window.sentFrames.last?.topLeft, corner)
    }

    /// The layout changes during the AX read. The check must not send the outdated frame over the newer layout
    @Test func testCheckDoesntOverrideNewerLayout() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        let window = appWindow(workspace, minimumWidth: 1000)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace() // 960, the window stays 1000
        window.onGetAxSizeForTest = {
            TestWindow.new(id: 3, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
            try await workspace.layoutWorkspace() // 640
        }
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), .learned)
        assertEquals(window.sentFrames.last?.size?.width, 640)
        assertEquals(window.effectiveMinimumSize.width, 1000)
    }

    /// A smaller minimum can't be observed (the layout never gives less than the learned minimum). Explicit user sizing
    /// forgets it
    @Test func testBalanceSizesForgetsMinimum() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        let window = appWindow(workspace, minimumWidth: 1300)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace()
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), .learned)
        window.minimumSizeForTest = .zero // E.g. the sidebar was hidden

        assertEquals(window.focusWindow(), true)
        await parseCommand("balance-sizes").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()
        assertEquals(window.lastAppliedLayoutPhysicalRect?.width, 960)
    }

    /// If the minimum is still real after balance-sizes, it's learned again (the window doesn't necessarily post
    /// kAXResizedNotification: it stays at its minimum)
    @Test func testBalanceSizesRelearnsRealMinimum() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        let window = appWindow(workspace, minimumWidth: 1300)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace()
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), .learned)

        assertEquals(window.focusWindow(), true)
        await parseCommand("balance-sizes").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace() // The window stays at 1300
        try await Task.sleep(for: .milliseconds(1200))
        assertEquals(window.effectiveMinimumSize.width, 1300)
        try await workspace.layoutWorkspace()
        assertEquals(window.lastAppliedLayoutPhysicalRect?.width, 1300)
    }

    /// Minimized windows are bound to a global container. They come back to the same workspace
    @Test func testMinimizeKeepsMinimum() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        let window = appWindow(workspace, minimumWidth: 1000)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace()
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), .learned)

        window.bind(to: macosMinimizedWindowsContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        window.bind(to: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        assertEquals(window.effectiveMinimumSize.width, 1000)
    }

    /// After learning, the check must not run again right away: the layout isn't updated yet, the refused frame would be
    /// sent again
    @Test func testNoRecheckRightAfterLearning() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        let window = appWindow(workspace, minimumWidth: 700)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
        TestWindow.new(id: 3, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace() // 640: the window stays 700
        window.onGetAxSizeForTest = { window.scheduleMinimumSizeCheck() } // A notification during the check
        window.scheduleMinimumSizeCheck()
        try await Task.sleep(for: .milliseconds(1200))
        assertEquals(window.effectiveMinimumSize.width, 700)
        // The layout sent 640 once, the check sent it once again. Nothing after learning
        assertEquals(window.sentFrames.count { $0.size?.width == 640 }, 2)
    }

    /// Some apps jitter. Both observations refused the size: the bigger one is learned
    @Test func testJitteringWindowLearnsTheBiggerSize() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        let window = appWindow(workspace, minimumWidth: 1000)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace() // 960: the window stays 1000
        let requested = try #require(window.lastAppliedLayoutPhysicalRect)
        window.onGetAxSizeForTest = { // The first read
            window.onGetAxSizeForTest = { window.setActualRectForTest(requested.with(\.width, 1012)) } // The second read
        }
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), .learned)
        assertEquals(window.effectiveMinimumSize.width, 1012)
    }

    @Test func testJitteringWindowLearnsTheBiggerSizeWhenItComesFirst() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        let window = appWindow(workspace, minimumWidth: 1000)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace() // 960: the window stays 1000
        readWidths(window, [1012]) // Then 1000 after the frame is sent again
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), .learned)
        assertEquals(window.effectiveMinimumSize.width, 1012)
    }

    /// E.g. an Electron app applies an older (bigger) frame late. A very different size isn't a confirmation: the check
    /// continues until the window refuses the same size twice
    @Test func testLateFrameIsNotLearned() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        let window = appWindow(workspace, minimumWidth: 1000)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace() // 960: the window stays 1000
        readWidths(window, [1400]) // Then 1000 after the frame is sent again
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), .learned)
        assertEquals(window.effectiveMinimumSize.width, 1000)
    }

    /// A notification that arrives during the cooldown after an inconclusive check must not be lost
    @Test func testRequestDuringTheCooldownIsNotLost() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        let window = appWindow(workspace, minimumWidth: 1000)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace() // 960: the window stays 1000
        readWidths(window, [1100, 1300, 1100, 1300]) // Very different sizes every time: inconclusive
        window.scheduleMinimumSizeCheck(confirmationDelay: .milliseconds(10), cooldown: .milliseconds(400))
        try await Task.sleep(for: .milliseconds(200))
        assertEquals(window.effectiveMinimumSize, .zero)
        #expect(window.minimumSizeCheckTask != nil) // The cooldown
        window.scheduleMinimumSizeCheck() // E.g. kAXResizedNotification
        try await Task.sleep(for: .milliseconds(500))
        assertEquals(window.effectiveMinimumSize.width, 1000)
        #expect(window.minimumSizeCheckTask == nil)
    }

    /// The layout weights follow the mouse during the drag. The check must not send the layout frame over the drag, nor
    /// learn the dragged size. The window is checked after the drag
    @Test func testWindowDraggedWithMouseIsCheckedAfterTheDrag() async throws {
        let workspace = Workspace.get(byName: name)
        #expect(workspace.focusWorkspace())
        let window = appWindow(workspace, minimumWidth: 1000)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer, adaptiveWeight: WEIGHT_AUTO)
        try await workspace.layoutWorkspace() // 960: the window stays 1000

        currentlyManipulatedWithMouseWindowId = window.windowId
        window.setActualRectForTest(try #require(window.lastAppliedLayoutPhysicalRect).with(\.width, 1400))
        window.invalidateSentFrame() // resizedObs
        let sentFramesCount = window.sentFrames.count
        assertEquals(try await window.checkMinimumSize(confirmationDelay: .zero), .fits)
        assertEquals(window.sentFrames.count, sentFramesCount)
        assertEquals(window.effectiveMinimumSize, .zero)

        try await resetManipulatedWithMouseIfPossible() // The mouse button is released
        try await workspace.layoutWorkspace() // 960: the window stays 1000
        try await Task.sleep(for: .milliseconds(800))
        assertEquals(window.effectiveMinimumSize.width, 1000)
    }
}

/// The next reads of the window size return `widths`, one per read (e.g. an app that jitters or applies late frames)
@MainActor
private func readWidths(_ window: TestWindow, _ widths: [CGFloat]) {
    guard let width = widths.first else { return }
    window.onGetAxSizeForTest = {
        window.setActualRectForTest(window.lastAppliedLayoutPhysicalRect?.with(\.width, width))
        readWidths(window, Array(widths.dropFirst()))
    }
}
