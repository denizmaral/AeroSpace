@testable import AppBundle
import AppKit
import Common
import Testing

/// The panel of the menu bar item: the strip customized like a toolbar, the keys of the workspaces, the windows of a
/// workspace as panes, what the styles show
@MainActor
@Suite(.serializedGlobally)
struct MenuBarPanelTest {
    init() { setUpWorkspacesForTests() }

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
        #expect(PanelDrag(PanelDrag.window(OpaqueWindowId(42)).string) == .window(OpaqueWindowId(42)))
        #expect(PanelDrag("T") == nil) // Text dropped from another app
        #expect(PanelDrag("marspace-window:x") == nil)
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
    @Test func testTheChipsTellWhatAStyleShows() {
        for style in MenuBarStyle.allCases {
            #expect(style.encodings.contains(.names))
        }
        #expect(MenuBarStyle.panes.encodings.contains(.windowCount))
        #expect(MenuBarStyle.skyline.encodings.contains(.windowCount))
        #expect(!MenuBarStyle.pills.encodings.contains(.windowCount))
        #expect(MenuBarStyle.shelf.encodings.contains(.apps))
        #expect(MenuBarStyle.workspaceApps.encodings.contains(.apps))
        #expect(!MenuBarStyle.workspaceApps.encodings.contains(.monitors)) // Only the focused workspace
    }
}
