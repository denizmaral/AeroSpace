import Common
import HotKey

extension Settings {
    /// The settings of the first launch. ⌃⌥ for everything: ⌥ alone types characters on most keyboard layouts
    static let defaults: Settings = {
        var settings = Settings()
        settings.appearance.gaps = Appearance.Gaps(
            innerHorizontal: 10, innerVertical: 10, outerLeft: 10, outerRight: 10, outerTop: 10, outerBottom: 10,
        )
        settings.appearance.focusBorder = Appearance.FocusBorder(
            isEnabled: true,
            color: .gradient(start: ARGB(0xEE33_CCFF), end: ARGB(0xEE00_FF99), direction: .topLeftToBottomRight),
            width: 4,
            radius: 12,
        )
        let controlOption: KeyChord.Modifiers = [.control, .option]
        let controlOptionShift: KeyChord.Modifiers = [.control, .option, .shift]
        func shortcut(_ modifiers: KeyChord.Modifiers, _ key: Key, _ actions: Action...) -> Shortcut {
            Shortcut(chord: KeyChord(modifiers, key), actions: IdentifiedList(actions))
        }
        settings.modes = [
            BindingMode(name: mainModeId, shortcuts: [
                shortcut(controlOption, .h, .focus(.left)),
                shortcut(controlOption, .j, .focus(.down)),
                shortcut(controlOption, .k, .focus(.up)),
                shortcut(controlOption, .l, .focus(.right)),
                shortcut(controlOptionShift, .h, .move(.left)),
                shortcut(controlOptionShift, .j, .move(.down)),
                shortcut(controlOptionShift, .k, .move(.up)),
                shortcut(controlOptionShift, .l, .move(.right)),
                shortcut(controlOption, .minus, .resize(.smart, .subtract(50))),
                shortcut(controlOption, .equal, .resize(.smart, .add(50))),
                shortcut(controlOption, .slash, .layout([.tiles, .horizontal, .vertical])),
                shortcut(controlOption, .comma, .layout([.accordion, .horizontal, .vertical])),
                shortcut(controlOption, .tab, .workspaceBackAndForth),
                shortcut(controlOptionShift, .tab, .moveWorkspaceToMonitor(.next, wrapAround: true)),
                shortcut(controlOptionShift, .semicolon, .enterMode("service")),
            ]),
            BindingMode(name: "service", shortcuts: [
                shortcut([], .escape, .enterMode(mainModeId)),
                shortcut([], .r, .flattenWorkspaceTree, .enterMode(mainModeId)),
                shortcut([], .f, .layout([.floating, .tiling]), .enterMode(mainModeId)),
                shortcut([], .delete, .closeAllWindowsButCurrent, .enterMode(mainModeId)),
                shortcut(controlOptionShift, .h, .joinWith(.left), .enterMode(mainModeId)),
                shortcut(controlOptionShift, .j, .joinWith(.down), .enterMode(mainModeId)),
                shortcut(controlOptionShift, .k, .joinWith(.up), .enterMode(mainModeId)),
                shortcut(controlOptionShift, .l, .joinWith(.right), .enterMode(mainModeId)),
            ]),
        ]
        // The workspaces of the keys that the shortcuts above don't use (H, J, K, L)
        settings.workspaces.persistent = "123456789ABCDEFGIMNOPQRSTUVWXYZ".map(String.init)
        settings.automation.onFocusedMonitorChanged = [.moveMouse(.monitorLazyCenter)]
        return settings
    }()
}
