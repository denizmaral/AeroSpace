@testable import AppBundle
import Foundation
import Testing

@MainActor
@Suite(.serializedGlobally)
struct MenuBarItemTest {
    init() { setUpWorkspacesForTests() }

    private func workspace(_ name: String, focused: Bool = false, visible: Bool = false, empty: Bool = false, apps: [URL] = []) -> WorkspaceViewModel {
        WorkspaceViewModel(
            name: name,
            suffix: "",
            appBundleUrls: apps,
            windowCount: empty ? 0 : max(1, apps.count),
            monitorName: nil,
            isFocused: focused,
            isEffectivelyEmpty: empty,
            isVisible: visible || focused,
            hasFullscreenWindows: false,
        )
    }

    private func state(_ workspaces: [WorkspaceViewModel], style: MenuBarStyle = .pills, favorites: [String] = []) -> MenuBarState {
        let focused = workspaces.first(where: \.isFocused)?.name ?? ""
        return MenuBarState(
            style: style,
            trayText: focused,
            trayItems: [TrayItem(type: .workspace, name: focused, isActive: true, hasFullscreenWindows: false)],
            workspaces: workspaces,
            settingsHaveProblems: false,
            favorites: favorites,
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
        #expect(state(workspaces, favorites: ["C", "B"]).strip.map(\.name) == ["B", "C", "T"])
        #expect(!state(workspaces).looksAnimatedTheSame(as: state(workspaces, favorites: ["C"])))
    }

    /// A click in the middle of a workspace focuses it, a click on the focused one opens the panel. The workspaces end
    /// where the drawing ends
    @Test(arguments: [MenuBarStyle.pills, .dots, .i3, .i3Ordered])
    func testAClickOnAWorkspaceFindsIt(style: MenuBarStyle) throws {
        let item = state([workspace("1"), workspace("C"), workspace("T", focused: true), workspace("X")], style: style)
        let slots = MenuBarItemContent.workspaceSlots(item, .white)
        let width = try #require(MenuBarItemContent(state: item, transition: nil, color: .white).cgImage).width
        #expect(slots.map(\.name) == (style == .i3 ? ["T", "1", "C", "X"] : ["1", "C", "T", "X"]))
        #expect(abs((slots.last?.maxX ?? 0) - CGFloat(width)) <= 1)
        for slot in slots {
            let clicked = MenuBarClicks.clickedWorkspace(item, atFraction: (slot.minX + slot.maxX) / 2 / CGFloat(width))
            #expect(clicked == (slot.name == "T" ? nil : slot.name))
        }
    }
}
