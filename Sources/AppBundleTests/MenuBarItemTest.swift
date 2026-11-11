@testable import AppBundle
import Foundation
import Testing

@MainActor
@Suite(.serializedGlobally)
struct MenuBarItemTest {
    init() { setUpWorkspacesForTests() }

    private func workspace(_ name: String, focused: Bool = false, visible: Bool = false, empty: Bool = false, apps: [URL] = [], windows: Int? = nil, monitor: Int = 0) -> WorkspaceViewModel {
        WorkspaceViewModel(
            name: name,
            suffix: "",
            appBundleUrls: apps,
            windowCount: windows ?? (empty ? 0 : max(1, apps.count)),
            monitorName: nil,
            isFocused: focused,
            isEffectivelyEmpty: empty,
            isVisible: visible || focused,
            hasFullscreenWindows: false,
            monitorIndex: monitor,
        )
    }

    private func state(_ workspaces: [WorkspaceViewModel], style: MenuBarStyle = .pills, favorites: [String] = [], groupsByMonitor: Bool = false) -> MenuBarState {
        let focused = workspaces.first(where: \.isFocused)?.name ?? ""
        return MenuBarState(
            style: style,
            trayText: focused,
            trayItems: [TrayItem(type: .workspace, name: focused, isActive: true, hasFullscreenWindows: false)],
            workspaces: workspaces,
            settingsHaveProblems: false,
            favorites: favorites,
            groupsByMonitor: groupsByMonitor,
        )
    }

    /// The item moves when the focus goes to another workspace. A new app in the focused workspace is just shown: no
    /// frames are drawn for it
    @Test func testOnlyAChangeOfTheWorkspacesIsAnimated() {
        let onT = state([workspace("T", focused: true), workspace("X")])
        let newApp = state([workspace("T", focused: true, apps: [URL(fileURLWithPath: "/Applications/Xcode.app")]), workspace("X")])
        let onX = state([workspace("T"), workspace("X", focused: true)])
        #expect(onT.looksAnimatedTheSame(as: newApp))
        #expect(!onT.looksAnimatedTheSame(as: onX))
        #expect(!onT.looksAnimatedTheSame(as: state(onT.workspaces, style: .dots)))

        MenuBarAnimator.shared.stateDidChange(from: onT, to: onX)
        #expect(MenuBarAnimator.shared.transition?.from == onT)
        #expect(MenuBarAnimator.shared.transition?.progress == 0)
    }

    /// The empty workspace that was left is gone after the change: it shrinks away where it was, after C. Workspace B,
    /// empty and not shown, isn't in the strip
    @Test func testAWorkspaceThatIsGoneStaysInPlaceInTheStrip() {
        let from = [workspace("1"), workspace("B", empty: true), workspace("C"), workspace("Z", focused: true, empty: true)]
        let to = [workspace("1"), workspace("B", empty: true), workspace("C", focused: true)]
        let entries = stripEntries(from: state(from).strip, to: state(to).strip)
        #expect(entries.map(\.name) == ["1", "C", "Z"])
        #expect(entries.last?.from?.isFocused == true)
        #expect(entries.last?.to == nil)
    }

    /// A workspace that gets its first window comes into the strip at its place
    @Test func testANewWorkspaceComesInAtItsPlace() {
        let from = [workspace("1", focused: true), workspace("M", empty: true), workspace("X")]
        let to = [workspace("1", focused: true), workspace("M"), workspace("X")]
        let entries = stripEntries(from: state(from).strip, to: state(to).strip)
        #expect(entries.map(\.name) == ["1", "M", "X"])
        #expect(entries[1].from == nil)
        #expect(entries[1].to != nil)
    }

    /// The favorite workspaces are always in the strip, also when they are empty, and the shown one too: the user sees
    /// where they are. Without favorites, the workspaces with windows
    @Test func testTheStripShowsTheFavoritesAndTheShownWorkspace() {
        let workspaces = [workspace("1"), workspace("B", empty: true), workspace("C"), workspace("T", focused: true), workspace("X")]
        #expect(state(workspaces).strip.map(\.name) == ["1", "C", "T", "X"])
        // In the order of the user (the panel inserts a new favorite at its place in the order of the workspaces)
        #expect(state(workspaces, favorites: ["C", "B"]).strip.map(\.name) == ["C", "B", "T"])
        #expect(!state(workspaces).looksAnimatedTheSame(as: state(workspaces, favorites: ["C"])))
    }

    /// The shown workspace that isn't a favorite comes after the favorites: they stay where they are, under the mouse
    @Test func testTheShownWorkspaceComesAfterTheFavorites() {
        let workspaces = [workspace("1", focused: true), workspace("C"), workspace("X")]
        #expect(state(workspaces, favorites: ["C", "X"]).strip.map(\.name) == ["C", "X", "1"])
    }

    /// From the shown workspace after the favorites to a favorite: it shrinks away at the end
    @Test func testFocusFromAGuestToAFavorite() {
        let from = state([workspace("1"), workspace("C"), workspace("T", focused: true)], favorites: ["1", "C"])
        let to = state([workspace("1"), workspace("C", focused: true), workspace("T")], favorites: ["1", "C"])
        let entries = stripEntries(from: from.strip, to: to.strip)
        #expect(entries.map(\.name) == ["1", "C", "T"])
        #expect(entries.last?.to == nil)
    }

    /// The focused workspace becomes a favorite: it moves from the end to its place, every workspace once
    @Test func testTheFocusedWorkspaceBecomesAFavorite() {
        let workspaces = [workspace("B"), workspace("T", focused: true), workspace("X")]
        let entries = stripEntries(from: state(workspaces, favorites: ["B", "X"]).strip, to: state(workspaces, favorites: ["B", "T", "X"]).strip) // toggleFavorite puts T at its place
        #expect(entries.map(\.name) == ["B", "T", "X"])
        #expect(entries.allSatisfy { $0.from != nil && $0.to != nil })
    }

    /// A window that comes or goes is animated in the styles that show the windows
    @Test func testAWindowThatComesIsAnimatedWhereTheWindowsAreShown() {
        let one = [workspace("T", focused: true), workspace("X")]
        let two = [workspace("T", focused: true, apps: [URL(fileURLWithPath: "/a.app"), URL(fileURLWithPath: "/b.app")]), workspace("X")]
        #expect(!state(one, style: .panes).looksAnimatedTheSame(as: state(two, style: .panes)))
        #expect(!state(one, style: .skyline).looksAnimatedTheSame(as: state(two, style: .skyline)))
        #expect(state(one, style: .pills).looksAnimatedTheSame(as: state(two, style: .pills)))
    }

    /// A click in the middle of a workspace focuses it, a click on the focused one opens the panel. The workspaces end
    /// where the drawing ends
    @Test(arguments: [MenuBarStyle.pills, .dots, .panes, .skyline, .shelf, .matrix, .heft, .i3, .i3Ordered])
    func testAClickOnAWorkspaceFindsIt(style: MenuBarStyle) throws {
        let item = state([workspace("1"), workspace("C"), workspace("T", focused: true), workspace("X")], style: style)
        let slots = MenuBarItemContent.workspaceSlots(item, .white)
        let image = try #require(MenuBarItemContent(state: item, transition: nil, color: .white).cgImage)
        let (width, height) = (CGFloat(image.width), CGFloat(image.height))
        #expect(slots.map(\.name) == (style == .i3 ? ["T", "1", "C", "X"] : ["1", "C", "T", "X"]))
        if style == .matrix { // The name tile of the focused workspace comes after the grid: not a slot
            #expect(slots.map(\.maxX).max() ?? 0 < width - 8)
        } else {
            #expect(abs((slots.last?.maxX ?? 0) - width) <= 1)
        }
        for slot in slots {
            let fromTop = min((slot.minY + min(slot.maxY, height)) / 2 / height, 0.999)
            let clicked = MenuBarClicks.clickedWorkspace(item, atFraction: (slot.minX + slot.maxX) / 2 / width, fromTop: fromTop)
            #expect(clicked == (slot.name == "T" ? nil : slot.name))
        }
    }

    /// Matrix: two rows, like a keypad. A click on the top edge of the screen is a click on the top row
    @Test func testMatrixHasTwoRows() throws {
        let item = state([workspace("1"), workspace("C"), workspace("T", focused: true), workspace("X")], style: .matrix)
        let width = try CGFloat(#require(MenuBarItemContent(state: item, transition: nil, color: .white).cgImage).width)
        let secondColumn = 30 / width // The cells are 20 wide
        #expect(MenuBarClicks.clickedWorkspace(item, atFraction: secondColumn, fromTop: 0) == "C")
        #expect(MenuBarClicks.clickedWorkspace(item, atFraction: secondColumn, fromTop: 0.9) == "X")
        #expect(MenuBarClicks.clickedWorkspace(item, atFraction: 10 / width, fromTop: 0.9) == nil) // T, focused
    }

    /// A window that comes or goes is animated only where it changes the look of the style
    @Test func testEveryStyleAnimatesItsOwnWindowCounts() {
        func animates(_ style: MenuBarStyle, _ from: Int, _ to: Int) -> Bool {
            !state([workspace("T", focused: true, windows: from)], style: style).looksAnimatedTheSame(as: state([workspace("T", focused: true, windows: to)], style: style))
        }
        #expect(!animates(.heft, 1, 2))
        #expect(animates(.heft, 2, 3))
        #expect(!animates(.matrix, 2, 3))
        #expect(animates(.matrix, 3, 4))
        #expect(!animates(.panes, 4, 5))
        #expect(!animates(.dots, 1, 2))
    }

    /// Grouped by monitor, the workspaces of a monitor are together, and the pills put a bay around them. Can't be seen
    /// with one monitor: the monitors are made up here
    @Test func testBaysGroupTheWorkspacesByMonitor() throws {
        let workspaces = [workspace("1"), workspace("C", monitor: 1), workspace("T", focused: true), workspace("X", visible: true, monitor: 1)]
        let item = state(workspaces, groupsByMonitor: true)
        #expect(item.strip.map(\.name) == ["1", "T", "C", "X"])
        let slots = MenuBarItemContent.workspaceSlots(item, .white)
        #expect(slots[2].minX - slots[1].maxX == 12) // The gap between the bays
        let width = try CGFloat(#require(MenuBarItemContent(state: item, transition: nil, color: .white).cgImage).width)
        #expect(abs((slots.last?.maxX ?? 0) - width) <= 1)
        #expect(MenuBarClicks.clickedWorkspace(item, atFraction: (slots[2].minX + slots[2].maxX) / 2 / width) == "C")
        #expect(state(workspaces).strip.map(\.name) == ["1", "C", "T", "X"]) // Not grouped
    }

    /// The focus mark stretches on its way like a drop, and is a little flatter halfway
    @Test func testTheDropStretches() {
        let from = CGRect(x: 0, y: 5, width: 20, height: 30), to = CGRect(x: 100, y: 5, width: 20, height: 30)
        #expect(dropRect(from: from, to: to, 0) == from)
        #expect(dropRect(from: from, to: to, 1) == to)
        let halfway = dropRect(from: from, to: to, 0.5)
        #expect(halfway.width > 20 && halfway.height < 30)
        #expect(dropRect(from: to, to: from, 0.5).width > 20) // Leftwards too
    }
}
