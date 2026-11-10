@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct OnWindowDetectedTest {
    init() { setUpWorkspacesForTests() }

    /// Every condition that the rule sets must hold. Without conditions: every window
    @Test func testTheMatcherChecksTheConditionsThatAreSet() async {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)

        assertEquals(await WindowMatcher().matches(window), true)
        assertEquals(await WindowMatcher(appId: "com.denizmaral.MarSpace.test-app", workspace: name).matches(window), true)
        assertEquals(await WindowMatcher(appId: "com.apple.mail").matches(window), false)
        assertEquals(await WindowMatcher(appId: "com.denizmaral.MarSpace.test-app", workspace: "other").matches(window), false)
    }

    @Test func testRunCommandReceivesDetectedWindowIdInEnv() async {
        let workspaceA = Workspace.get(byName: "a")
        let focused = TestWindow.new(id: 1, parent: workspaceA.rootTilingContainer)
        let detected = TestWindow.new(id: 2, parent: workspaceA.rootTilingContainer)
        assertEquals(focused.focusWindow(), true)
        assertEquals(globalFocus.windowOrNil?.windowId, 1)

        config.onWindowDetected = [
            WindowDetectedCallback(run: parseCommand("move-node-to-workspace b").cmdOrDie), // Every window
        ]

        await runOnWindowDetected(ifConventional: detected) // todo: tryOnWindowDetected must not be called manually in tests

        assertEquals((Workspace.get(byName: "b").rootTilingContainer.children.singleOrNil() as? Window)?.windowId, 2)
        assertEquals((workspaceA.rootTilingContainer.children.singleOrNil() as? Window)?.windowId, 1)
    }

    /// The title is read from the app (an accessibility round trip): only if the other conditions hold
    @Test func testTheTitleIsReadLast() async throws {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        let title = try CaseInsensitiveRegex.new("testwindow\\(1\\)").get()

        assertEquals(await WindowMatcher(appId: "com.apple.mail", windowTitleRegexSubstring: title).matches(window), false)
        assertEquals(await WindowMatcher(windowTitleRegexSubstring: title, workspace: "other").matches(window), false)
        assertEquals(await WindowMatcher(windowTitleRegexSubstring: title, duringStartup: true).matches(window), false)
        assertEquals(window.titleReadsForTest, 0)

        assertEquals(await WindowMatcher(appId: "com.denizmaral.MarSpace.test-app", windowTitleRegexSubstring: title).matches(window), true)
        assertEquals(window.titleReadsForTest, 1)
    }
}
