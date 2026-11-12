@testable import AppBundle
import AppKit
import Common
import SwiftUI
import Testing

/// The panel of the menu bar item: its height on the screen, the strip customized like a toolbar, the keys of the
/// workspaces, the windows of a workspace as panes, what the styles show
@MainActor
@Suite(.serializedGlobally)
struct MenuBarPanelTest {
    init() { setUpWorkspacesForTests() }

    // MARK: - The height

    /// The built-in display of a MacBook Pro 14" (1800×1169 points) with the Dock at the bottom: the item is in the menu
    /// bar of 40 points, the panel 2 points under it
    private let builtIn = (top: CGFloat(1127), visibleFrame: CGRect(x: 0, y: 90, width: 1800, height: 1039))

    @Test func testThePanelIsNotHigherThanTheScreenHasUnderTheItem() {
        let maxHeight = MenuBarPanelFrame.maxHeight(top: builtIn.top, visibleFrame: builtIn.visibleFrame)
        #expect(maxHeight == 1029) // Down to the Dock, less the margin
        let topLeft = CGPoint(x: 1215, y: builtIn.top)
        // The content fits: the panel is as high as it. The top left corner stays under the item
        #expect(MenuBarPanelFrame.frame(size: CGSize(width: 312, height: 423), topLeft: topLeft, maxHeight: maxHeight) == CGRect(x: 1215, y: 704, width: 312, height: 423))
        // It doesn't fit: the panel ends above the Dock
        let limited = MenuBarPanelFrame.frame(size: CGSize(width: 312, height: 1235), topLeft: topLeft, maxHeight: maxHeight)
        #expect(limited == CGRect(x: 1215, y: 98, width: 312, height: 1029))
        #expect(limited.minY == builtIn.visibleFrame.minY + MenuBarPanelFrame.bottomMargin)
        #expect(limited.maxY == topLeft.y)
    }

    /// The coordinates of a screen under or above the main one, and of one without a Dock
    @Test func testTheHeightOfThePanelOnOtherScreens() {
        // An external display of 2560×1707 above the built-in one, without a Dock: down to its bottom edge
        let above = CGRect(x: -380, y: 1169, width: 2560, height: 1667)
        #expect(MenuBarPanelFrame.maxHeight(top: 1169 + 1707 - 42, visibleFrame: above) == 1657)
        // The same display below the main one: its coordinates are negative
        let below = CGRect(x: -380, y: -1707, width: 2560, height: 1667)
        #expect(MenuBarPanelFrame.maxHeight(top: -42, visibleFrame: below) == 1657)
        let frame = MenuBarPanelFrame.frame(size: CGSize(width: 312, height: 2000), topLeft: CGPoint(x: 100, y: -42), maxHeight: 1657)
        #expect(frame == CGRect(x: 100, y: -1699, width: 312, height: 1657))
        #expect(frame.minY == below.minY + MenuBarPanelFrame.bottomMargin)
    }

    /// An item that isn't on any screen, or a screen that has nothing under the item: the panel still has a height
    @Test func testThePanelHasAHeightWithoutAScreen() {
        #expect(MenuBarPanelFrame.maxHeight(top: 0, visibleFrame: .zero) == MenuBarPanelFrame.minHeight)
        #expect(MenuBarPanelFrame.maxHeight(top: 100, visibleFrame: CGRect(x: 0, y: 90, width: 1800, height: 50)) == MenuBarPanelFrame.minHeight)
    }

    /// The workspaces of the owner: nine of them with windows, T focused, the other ones empty (and persistent)
    /// - Parameter style: the chosen style. "Workspace and apps" shows no row of workspaces: the strip says so while
    ///   it's edited, which makes the panel higher
    private func withWorkspaces<T>(style: MenuBarStyle = .workspaceApps, _ body: () -> T) -> T {
        let model = TrayMenuModel.shared
        let before = (model.workspaces, model.trayText, model.trayItems, model.isEnabled, model.axPermissionStatus, model.experimentalUISettings)
        defer { (model.workspaces, model.trayText, model.trayItems, model.isEnabled, model.axPermissionStatus, model.experimentalUISettings) = before }
        // Read from defaults of its own, and nothing is written: the settings are saved only when one of them is set
        let suite = "MenuBarPanelTest"
        let defaults = UserDefaults(suiteName: suite).orDie()
        defaults.removePersistentDomain(forName: suite)
        defaults.set(style.rawValue, forKey: ExperimentalUISettingsItems.displayStyle.rawValue)
        model.experimentalUISettings = ExperimentalUISettings(defaults)
        defaults.removePersistentDomain(forName: suite)
        let windows = ["1": 2, "C": 1, "F": 4, "G": 1, "I": 1, "M": 1, "P": 1, "T": 4, "X": 1]
        model.workspaces = "123456789ABCDEFGIMNOPQRSTUVWXYZ".map { name in
            let count = windows[String(name)] ?? 0
            return WorkspaceViewModel(
                name: String(name),
                suffix: "",
                appBundleUrls: [],
                windowCount: count,
                monitorName: nil,
                isFocused: name == "T",
                isEffectivelyEmpty: count == 0,
                isVisible: name == "T",
                hasFullscreenWindows: false,
                windows: (0 ..< count).map { WindowSummary(windowId: OpaqueWindowId(UInt64(name.unicodeScalars.first.orDie().value) * 10 + UInt64($0)), appBundleUrl: nil) },
            )
        }
        model.trayText = "T"
        model.trayItems = [TrayItem(type: .workspace, name: "T", isActive: true, hasFullscreenWindows: false)]
        model.isEnabled = true
        model.axPermissionStatus = .granted
        return body()
    }

    /// The height that the window of the panel gets: what its content asks for, once it's laid out (a switch is higher
    /// before)
    private func panelHeight(maxHeight: CGFloat, isStylePickerShown: Bool = false, isEditingStrip: Bool = false) -> CGFloat {
        let content = MenuBarPanelWindow.content(maxHeight: maxHeight, isStylePickerShown: isStylePickerShown, isEditingStrip: isEditingStrip)
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// "The view is now too tall": with the styles open, the panel was 1235 points high, on a display that has 1029
    /// under the item. Every state fits it now without scrolling, with room for more workspaces (a row of tiles is 72
    /// points), and the panel as it opens isn't higher than it was (423)
    @Test func testThePanelFitsTheBuiltInDisplay() {
        withWorkspaces {
            let closed = panelHeight(maxHeight: .infinity)
            let editing = panelHeight(maxHeight: .infinity, isEditingStrip: true)
            let styles = panelHeight(maxHeight: .infinity, isStylePickerShown: true)
            let both = panelHeight(maxHeight: .infinity, isStylePickerShown: true, isEditingStrip: true)
            #expect(closed <= 424, "\(closed)")
            #expect(editing <= 520, "\(editing)") // 500, with the note that the chosen style shows no row
            #expect(styles <= 900, "\(styles)") // 855
            #expect(both <= 950, "\(both)") // 931
        }
    }

    /// The details under the cards are of the style under the mouse: the panel is as high for one as for the other, its
    /// window doesn't move under the mouse
    @Test func testThePanelIsAsHighForEveryStyle() {
        let heights = MenuBarStyle.allCases.map { style in
            withWorkspaces(style: style) { panelHeight(maxHeight: .infinity, isStylePickerShown: true) }
        }
        #expect(Set(heights).count == 1, "\(heights)")
    }

    /// A screen that has less than the panel wants: the panel takes what there is (and scrolls under its header), in
    /// every state
    @Test func testThePanelIsNeverHigherThanItsMaxHeight() {
        withWorkspaces {
            #expect(panelHeight(maxHeight: 400) == 400)
            #expect(panelHeight(maxHeight: 400, isEditingStrip: true) == 400)
            #expect(panelHeight(maxHeight: 400, isStylePickerShown: true) == 400)
            #expect(panelHeight(maxHeight: 400, isStylePickerShown: true, isEditingStrip: true) == 400)
            // And not higher than its content on a screen that has more
            #expect(panelHeight(maxHeight: 3000) == panelHeight(maxHeight: .infinity))
            #expect(panelHeight(maxHeight: 3000, isStylePickerShown: true) == panelHeight(maxHeight: .infinity, isStylePickerShown: true))
        }
    }

    // MARK: - The strip

    /// Dropped before another workspace, at the end, within the strip (reordered)
    @Test func testADroppedWorkspaceGoesWhereItIsDropped() {
        #expect(StripWell.favorites(dropping: "T", before: "X", in: ["1", "X"]) == ["1", "T", "X"])
        #expect(StripWell.favorites(dropping: "T", before: nil, in: ["1", "X"]) == ["1", "X", "T"])
        #expect(StripWell.favorites(dropping: "X", before: "1", in: ["1", "T", "X"]) == ["X", "1", "T"])
        #expect(StripWell.favorites(dropping: "1", before: nil, in: ["1", "T", "X"]) == ["T", "X", "1"])
        // Dropped before a workspace that isn't in the strip (the one shown only because it's focused): at the end
        #expect(StripWell.favorites(dropping: "T", before: "M", in: ["1", "X"]) == ["1", "X", "T"])
    }

    /// The last one dragged out: no favorites, the strip shows every workspace with windows again
    @Test func testADraggedOutWorkspaceIsGone() {
        #expect(StripWell.favorites(removing: "T", from: ["1", "T", "X"]) == ["1", "X"])
        #expect(StripWell.favorites(removing: "T", from: ["T"]) == [])
    }

    @Test func testWhatIsDraggedSurvivesTheString() {
        #expect(PanelDrag(PanelDrag.workspace("T").string) == .workspace("T"))
        #expect(PanelDrag(PanelDrag.stripWorkspace("T").string) == .stripWorkspace("T"))
        #expect(PanelDrag(PanelDrag.window(OpaqueWindowId(42)).string) == .window(OpaqueWindowId(42)))
        #expect(PanelDrag("T") == nil) // Text dropped from another app
        #expect(PanelDrag("marspace-window:x") == nil)
    }

    /// The strip takes a workspace of the palette and one of its own (to another place). Only one of its own leaves it,
    /// dropped on the palette: a workspace of the palette that is dropped back there changes nothing
    @Test func testTheStripTakesAWorkspaceFromThePaletteAndFromItself() {
        #expect(PanelDrag.workspace("T").droppedWorkspace == "T")
        #expect(PanelDrag.stripWorkspace("T").droppedWorkspace == "T")
        #expect(PanelDrag.window(OpaqueWindowId(42)).droppedWorkspace == nil)
        #expect(PanelDrag.workspace("T") != PanelDrag.stripWorkspace("T"))
    }

    // MARK: - The keys

    private let workspaces = ["1", "2", "C", "G", "T", "X"]

    private func keyDown(_ characters: String, ignoringModifiers: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: ignoringModifiers, isARepeat: false, keyCode: keyCode,
        ))
    }

    @Test func testTheKeyOfAWorkspaceFocusesIt() throws {
        #expect(PanelKeyAction.of(try keyDown("t", ignoringModifiers: "t", [], keyCode: 17), workspaces: workspaces) == .focus("T"))
        #expect(PanelKeyAction.of(try keyDown("T", ignoringModifiers: "T", .shift, keyCode: 17), workspaces: workspaces) == .focus("T"))
        #expect(PanelKeyAction.of(try keyDown("1", ignoringModifiers: "1", [], keyCode: 18), workspaces: workspaces) == .focus("1"))
        #expect(PanelKeyAction.of(try keyDown("z", ignoringModifiers: "z", [], keyCode: 16), workspaces: workspaces) == nil)
    }

    /// Option types another character on a Swiss German keyboard (Option-G is ©): the key is matched without it
    @Test func testOptionAndTheKeyOfAWorkspaceKeepsItInTheMenuBar() throws {
        #expect(PanelKeyAction.of(try keyDown("©", ignoringModifiers: "g", .option, keyCode: 5), workspaces: workspaces) == .toggleFavorite("G"))
        #expect(PanelKeyAction.of(try keyDown("¡", ignoringModifiers: "1", .option, keyCode: 18), workspaces: workspaces) == .toggleFavorite("1"))
    }

    /// ⌘Q quits, ⌃ is for the shortcuts of MarSpace: not the keys of the workspaces
    @Test func testShortcutsAreNotTheKeysOfTheWorkspaces() throws {
        #expect(PanelKeyAction.of(try keyDown("q", ignoringModifiers: "q", .command, keyCode: 12), workspaces: ["Q"]) == nil)
        #expect(PanelKeyAction.of(try keyDown("t", ignoringModifiers: "t", .control, keyCode: 17), workspaces: workspaces) == nil)
        #expect(PanelKeyAction.of(try keyDown("t", ignoringModifiers: "t", [.control, .option], keyCode: 17), workspaces: workspaces) == nil)
    }

    // MARK: - The windows of a tile

    @Test func testTheWindowsAreSplitLikeTheTiles() {
        let size = CGSize(width: 40, height: 24)
        let layouts = (0 ... 6).map { PaneMap.panes(count: $0, in: size, gap: 2) }
        #expect(layouts.map(\.rects.count) == [0, 1, 2, 3, 4, 4, 4])
        #expect(layouts.map(\.hidden) == [0, 0, 0, 0, 0, 1, 2])
        #expect(layouts[1].rects == [CGRect(x: 0, y: 0, width: 40, height: 24)])
        #expect(layouts[2].rects.map(\.width) == [19, 19])
        #expect(layouts[4].rects.last == CGRect(x: 21, y: 13, width: 19, height: 11))
        for (rects, _) in layouts {
            #expect(rects.allSatisfy { CGRect(origin: .zero, size: size).contains($0) })
            for (i, a) in rects.enumerated() {
                for b in rects[(i + 1)...] { #expect(!a.intersects(b)) }
            }
        }
    }

    // MARK: - The styles

    /// Every style shows names, the ones that draw the windows or the apps say so
    @Test func testTheDetailsTellWhatAStyleShows() {
        for style in MenuBarStyle.allCases {
            #expect(style.encodings.contains(.names))
        }
        #expect(MenuBarStyle.panes.encodingsText == "names, windows, monitors")
        #expect(MenuBarStyle.workspaceApps.encodingsText == "names, apps")
        #expect(MenuBarStyle.panes.encodings.contains(.windowCount))
        #expect(MenuBarStyle.skyline.encodings.contains(.windowCount))
        #expect(!MenuBarStyle.pills.encodings.contains(.windowCount))
        #expect(MenuBarStyle.shelf.encodings.contains(.apps))
        #expect(MenuBarStyle.workspaceApps.encodings.contains(.apps))
        #expect(!MenuBarStyle.workspaceApps.encodings.contains(.monitors)) // Only the focused workspace
    }
}
