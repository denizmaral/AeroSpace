import Common
import HotKey

extension Settings {
    /// The settings of the first launch. ⌃⌥ for everything: ⌥ alone types characters on most keyboard layouts.
    ///
    /// The arrow keys focus and move, like the window shortcuts that Mac users know (Rectangle, Magnet), not H, J, K
    /// and L. And there is one mode: no action is behind a second set of shortcuts, where plain keys act on the
    /// windows (AeroSpace's service mode: once in it, F made the window floating and ⌫ closed all the others)
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
                shortcut(controlOption, .leftArrow, .focus(.left)),
                shortcut(controlOption, .downArrow, .focus(.down)),
                shortcut(controlOption, .upArrow, .focus(.up)),
                shortcut(controlOption, .rightArrow, .focus(.right)),
                shortcut(controlOptionShift, .leftArrow, .move(.left)),
                shortcut(controlOptionShift, .downArrow, .move(.down)),
                shortcut(controlOptionShift, .upArrow, .move(.up)),
                shortcut(controlOptionShift, .rightArrow, .move(.right)),
                shortcut(controlOption, .minus, .resize(.smart, .subtract(50))),
                shortcut(controlOption, .equal, .resize(.smart, .add(50))),
                shortcut(controlOption, .slash, .layout([.tiles, .horizontal, .vertical])),
                shortcut(controlOption, .comma, .layout([.accordion, .horizontal, .vertical])),
                shortcut(controlOption, .tab, .workspaceBackAndForth),
                shortcut(controlOptionShift, .tab, .moveWorkspaceToMonitor(.next, wrapAround: true)),
                shortcut(controlOptionShift, .space, .layout([.floating, .tiling])),
                shortcut(controlOptionShift, .delete, .flattenWorkspaceTree),
            ]),
        ]
        // A workspace for every key that types a digit or a letter: the shortcuts above use none of them
        settings.workspaces.persistent = "123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)
        settings.automation.onFocusedMonitorChanged = [.moveMouse(.monitorLazyCenter)]
        return settings
    }()
}
