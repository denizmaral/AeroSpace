@testable import AppBundle
import Common
import Foundation
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

    /// A rule changed in the settings window runs on the open windows that it matches: they don't have to be opened again
    /// (System Settings stayed tiling after a rule made it floating)
    @Test func testAChangedRuleRunsOnTheOpenWindowsThatItMatches() async {
        let changed = UUID()
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        let notMatched = TestWindow.new(id: 2, parent: Workspace.get(byName: "b").rootTilingContainer)
        config.onWindowDetected = [
            WindowDetectedCallback(matcher: WindowMatcher(appId: "com.apple.mail"), run: parseCommand("move-node-to-workspace m").cmdOrDie),
            WindowDetectedCallback(
                matcher: WindowMatcher(appId: "com.denizmaral.MarSpace.test-app", workspace: "a"),
                run: parseCommand("layout floating").cmdOrDie,
                ruleId: changed,
            ),
            WindowDetectedCallback(run: parseCommand("move-node-to-workspace c").cmdOrDie), // Every window
        ]

        await runChangedWindowRule(changed)

        assertEquals(window.isFloating, true)
        assertEquals(window.nodeWorkspace?.name, "a") // Only the changed rule runs
        assertEquals(notMatched.isFloating, false)
        assertEquals(notMatched.nodeWorkspace?.name, "b")
    }

    /// A window gets the changed rule only if it would get it when it opens: the first rule that matches it runs, the next
    /// ones only after a rule that checks them too
    @Test func testAChangedRuleLeavesTheWindowsOfTheRulesBeforeIt() async {
        let changed = UUID()
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        let ofAnEarlierRule = TestWindow.new(id: 2, parent: Workspace.get(byName: "b").rootTilingContainer)
        let earlierRule = WindowDetectedCallback(matcher: WindowMatcher(workspace: "b"), run: parseCommand("move-node-to-workspace c").cmdOrDie)
        let changedRule = WindowDetectedCallback(run: parseCommand("layout floating").cmdOrDie, ruleId: changed) // Every window
        config.onWindowDetected = [earlierRule, changedRule]

        await runChangedWindowRule(changed)
        assertEquals(window.isFloating, true)
        assertEquals(ofAnEarlierRule.isFloating, false)
        assertEquals(ofAnEarlierRule.nodeWorkspace?.name, "b") // The earlier rule doesn't run again

        config.onWindowDetected = [earlierRule.with(\.checkFurtherCallbacks, true), changedRule]
        await runChangedWindowRule(changed)
        assertEquals(ofAnEarlierRule.isFloating, true)
        assertEquals(ofAnEarlierRule.nodeWorkspace?.name, "b")
    }

    /// A rule that does nothing yet (no action) isn't compiled: nothing runs
    @Test func testARuleThatIsNotThereRunsNothing() async {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        config.onWindowDetected = [WindowDetectedCallback(run: parseCommand("layout floating").cmdOrDie, ruleId: UUID())]
        await runChangedWindowRule(UUID())
        assertEquals(window.isFloating, false)
    }

    /// The settings window knows its rules by id: the compiled rules keep it
    @Test func testTheCompiledRulesKeepTheIdsOfTheRules() {
        var settings = Settings()
        settings.windowRules = [
            Settings.WindowRule(), // Does nothing yet: not compiled
            Settings.WindowRule(condition: Settings.WindowCondition(appBundleId: "com.apple.mail"), actions: [.layout([.floating])]),
        ]
        assertEquals(settings.compile().config.onWindowDetected.map(\.ruleId), [settings.windowRules.ids[1]])
    }
}
