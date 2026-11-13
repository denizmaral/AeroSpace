import Common
import SwiftUI

// MARK: - Shortcuts

/// The mode and the search of the shortcut list. Owned by the settings window: its toolbar edits them, and switching panes
/// doesn't render the list again
@MainActor
@Observable
final class ShortcutsPaneState {
    var modeName = mainModeId
    var search = ""
    var isAddingMode = false
}

/// The toolbar of the window while the shortcuts are shown
struct ShortcutsToolbar: ToolbarContent {
    @Bindable var state: ShortcutsPaneState
    @Bindable var model: SettingsModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            Picker("Mode", selection: $state.modeName) {
                ForEach(model.settings.modes) { Text($0.name.capitalized).tag($0.name) }
            }
            .pickerStyle(.segmented)
            .help("A mode is a set of shortcuts, active until a shortcut switches to another mode")
            Menu {
                Button("New mode…") { state.isAddingMode = true }
                if state.modeName != mainModeId {
                    Button("Remove the \(state.modeName.capitalized) mode", role: .destructive) {
                        model.removing("Remove Mode", "The \(state.modeName) mode was removed") { settings in settings.modes.removeAll { $0.name == state.modeName } }
                        state.modeName = mainModeId
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
        }
        ToolbarItem(placement: .primaryAction) {
            TextField("Search", text: $state.search, prompt: Text("Search shortcuts"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
    }
}

struct ShortcutsPane: View {
    @Bindable var model: SettingsModel
    /// The mode and the search: the toolbar of the window edits them (see ``ShortcutsToolbar``)
    @Bindable var state: ShortcutsPaneState
    @State private var editing: IdentifiedList<Settings.Shortcut>.ID? = nil
    @State private var newModeName = ""

    private var modeIndex: Int? { model.settings.modes.firstIndex { $0.name == state.modeName } }

    var body: some View {
        List {
            if state.modeName == mainModeId, state.search.isEmpty {
                Section {
                    WorkspaceShortcutRow(
                        title: "Go to a workspace", symbol: "square.grid.2x2", modifiers: $model.settings.workspaceShortcuts.goTo,
                        defaultModifiers: [.control, .option],
                    )
                    if model.settings.workspaceShortcuts.goTo != nil {
                        HStack(spacing: 12) {
                            Text("Press it again to go back to the previous workspace")
                            Spacer(minLength: 12)
                            Toggle("Press it again to go back to the previous workspace", isOn: $model.settings.workspaceShortcuts.goToTogglesBack)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                        .padding(.leading, 36) // Under the title of "Go to a workspace"
                        .help("Press the shortcut of a workspace twice to look at it and come back")
                    }
                    WorkspaceShortcutRow(
                        title: "Move the window to a workspace", symbol: "macwindow.and.cursorarrow",
                        modifiers: $model.settings.workspaceShortcuts.moveWindowTo, defaultModifiers: [.control, .option, .shift],
                    )
                    ForEach(model.problems(at: "Shortcuts › \(mainModeId) › Workspaces"), id: \.message) { problem in
                        Label(problem.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                } header: {
                    Text("Workspaces")
                } footer: {
                    Text(workspaceFooter).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let modeIndex {
                let shortcuts = model.settings.modes[modeIndex].shortcuts
                let displayed = displayed(shortcuts)
                ForEach(ShortcutGroup.allCases) { group in
                    let inGroup = displayed.filter { ShortcutGroup($0.shortcut) == group }
                    if !inGroup.isEmpty {
                        Section {
                            ForEach(inGroup, id: \.id) { row($0.id, $0.shortcut) }
                        } header: {
                            Text(group.title)
                        }
                    }
                }
                if displayed.isEmpty {
                    ContentUnavailableView.search(text: state.search)
                }
                Section {
                    Button {
                        // Does nothing (and isn't registered) until an action is chosen
                        model.store.update("Add Shortcut") { $0.modes[modeIndex].shortcuts.append(Settings.Shortcut(chord: KeyChord([.control, .option], .f1), actions: [])) }
                        editing = model.settings.modes[modeIndex].shortcuts.lastId
                    } label: {
                        Label("Add a shortcut", systemImage: "plus")
                    }
                } footer: {
                    Text(state.modeName == mainModeId
                        ? "Click a shortcut to change its keys or what it does."
                        : "Active after a shortcut switches to the \(state.modeName) mode, until one switches back.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .id(model.keyboardLayoutChanges) // The key labels follow the keyboard layout of macOS
        .sheet(isPresented: $state.isAddingMode) {
            NameSheet(title: "New mode", placeholder: "e.g. resize", name: $newModeName) {
                let name = newModeName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !model.settings.modes.contains(where: { $0.name == name }) {
                    model.settings.modes.append(Settings.BindingMode(name: name, shortcuts: [
                        Settings.Shortcut(chord: KeyChord([], .escape), actions: [.enterMode(mainModeId)]),
                    ]))
                    state.modeName = name
                }
                newModeName = ""
            }
        }
        .onChange(of: state.modeName) { editing = nil }
    }

    private func row(_ id: IdentifiedList<Settings.Shortcut>.ID, _ shortcut: Settings.Shortcut) -> some View {
        let keyNames = KeyNames.standard
        return ShortcutRow(
            shortcut: shortcut,
            problem: model.problems(at: "Shortcuts › \(state.modeName) › \(keyNames.notation(shortcut.chord))").first,
        )
        .contentShape(Rectangle())
        .onTapGesture { editing = id }
        .popover(isPresented: Binding(get: { editing == id }, set: { if !$0 { editing = nil } }), arrowEdge: .trailing) {
            // Built again while it closes, after the shortcut may have been removed
            if let current = currentShortcut(id) { shortcutEditor(id, current) }
        }
    }

    /// The shortcut of the shown mode with the id. nil: it was removed
    private func currentShortcut(_ id: IdentifiedList<Settings.Shortcut>.ID) -> Settings.Shortcut? {
        model.settings.modes.first { $0.name == state.modeName }?.shortcuts[id: id]
    }

    private func shortcutEditor(_ id: IdentifiedList<Settings.Shortcut>.ID, _ initial: Settings.Shortcut) -> some View {
        let modeName = state.modeName
        // By the name of the mode and the id of the shortcut: a removed shortcut is read as it was and isn't written
        let binding = Binding<Settings.Shortcut>(
            get: { currentShortcut(id) ?? initial },
            set: { value in
                model.store.update { settings in
                    if let mode = settings.modes.firstIndex(where: { $0.name == modeName }) { settings.modes[mode].shortcuts[id: id] = value }
                }
            },
        )
        return ShortcutEditor(
            shortcut: binding,
            isRecording: $model.isRecordingShortcut,
            modes: model.settings.modes.map(\.name),
            workspaces: model.settings.workspaces.persistent,
            remove: {
                editing = nil
                model.removing("Delete Shortcut", "Shortcut deleted") { settings in
                    if let mode = settings.modes.firstIndex(where: { $0.name == modeName }) { settings.modes[mode].shortcuts[id: id] = nil }
                }
            },
        )
    }

    /// The matching shortcuts in a readable order: by action, then by parameter (directions in reading order, workspaces
    /// naturally sorted). The stored order doesn't change
    private func displayed(_ shortcuts: IdentifiedList<Settings.Shortcut>) -> [(id: IdentifiedList<Settings.Shortcut>.ID, shortcut: Settings.Shortcut, index: Int)] {
        let keyNames = KeyNames.standard
        let query = state.search.trimmingCharacters(in: .whitespaces).lowercased()
        return zip(shortcuts.ids, shortcuts).enumerated().map { (id: $1.0, shortcut: $1.1, index: $0) }
            .filter { entry in
                guard !query.isEmpty else { return true }
                let shortcut = entry.shortcut
                return keyNames.notation(shortcut.chord).contains(query) || KeyLabels.symbols(shortcut.chord).lowercased().contains(query)
                    || shortcut.actions.contains { $0.summary.lowercased().contains(query) || $0.commandLine.lowercased().contains(query) }
            }
            .sorted { lhs, rhs in
                let (a, b) = (lhs.shortcut.actions.first, rhs.shortcut.actions.first)
                let (kindA, kindB) = (a.map { ActionKind.allCases.firstIndex(of: ActionKind($0)) ?? 0 } ?? .max, b.map { ActionKind.allCases.firstIndex(of: ActionKind($0)) ?? 0 } ?? .max)
                if kindA != kindB { return kindA < kindB }
                let (keyA, keyB) = (a?.sortKey ?? "", b?.sortKey ?? "")
                if keyA != keyB { return keyA.localizedStandardCompare(keyB) == .orderedAscending }
                return lhs.index < rhs.index
            }
    }
}

extension ShortcutsPane {
    /// Which workspaces get shortcuts, with an example on the keyboard layout of macOS
    private var workspaceFooter: String {
        let names = model.settings.workspaces.persistent.filter { $0.count == 1 }
        guard let example = names.last else {
            return "Workspaces named with one key (1 … 9, A … Z) get these shortcuts. Add them under Workspaces."
        }
        let modifiers = model.settings.workspaceShortcuts.goTo.map { KeyLabels.symbols(KeyChord($0, .a)).dropLast() } ?? ""
        let list = names.count > 12 ? "\(names.prefix(6).joined(separator: " ")) … \(names.suffix(3).joined(separator: " "))" : names.joined(separator: " ")
        return "For the workspaces \(list): the modifier keys and the key of the name, e.g. \(modifiers)\(example) goes to workspace \(example)."
    }
}

/// The shortcuts of all workspaces at once: modifier keys, plus the key of the name of the workspace
private struct WorkspaceShortcutRow: View {
    let title: String
    let symbol: String
    @Binding var modifiers: KeyChord.Modifiers?
    let defaultModifiers: KeyChord.Modifiers

    private static let all: [(modifier: KeyChord.Modifiers, symbol: String, name: String)] = [
        (.control, "⌃", "Control"), (.option, "⌥", "Option"), (.shift, "⇧", "Shift"), (.command, "⌘", "Command"),
    ]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.teal.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title).foregroundStyle(modifiers == nil ? .secondary : .primary)
            Spacer(minLength: 12)
            if let modifiers {
                HStack(spacing: 3) {
                    ForEach(Self.all, id: \.symbol) { item in
                        let isOn = modifiers.contains(item.modifier)
                        Button {
                            self.modifiers = modifiers.symmetricDifference(item.modifier)
                        } label: {
                            Text(item.symbol)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .frame(width: 22, height: 20)
                                .foregroundStyle(isOn ? Color.white : Color.secondary)
                                .background(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.background.secondary), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .help("\(item.name): \(isOn ? "on" : "off")")
                        .accessibilityLabel(item.name)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                    Text("+").foregroundStyle(.tertiary).padding(.horizontal, 2)
                    Text("1…Z")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(height: 20)
                        .padding(.horizontal, 6)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        .help("The key of the name of the workspace")
                }
            }
            Toggle(title, isOn: Binding(get: { modifiers != nil }, set: { modifiers = $0 ? defaultModifiers : nil }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

/// A shortcut in the list: what it does, and its keys
private struct ShortcutRow: View {
    let shortcut: Settings.Shortcut
    let problem: SettingsProblem?

    var body: some View {
        HStack(spacing: 12) {
            ActionIcon(action: shortcut.actions.first)
            VStack(alignment: .leading, spacing: 1) {
                Text(shortcut.actions.first?.summary ?? "Does nothing")
                    .foregroundStyle(shortcut.actions.isEmpty ? .secondary : .primary)
                if shortcut.actions.count > 1 {
                    Text("then " + shortcut.actions.dropFirst().map(\.summary).joined(separator: ", then "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            if let problem {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(problem.message)
            }
            KeyCaps(chord: shortcut.chord)
        }
        .padding(.vertical, 2)
    }
}

/// The keys of a shortcut, each on its own keycap: ⌃ ⌥ H
struct KeyCaps: View {
    let chord: KeyChord
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: size, weight: .medium, design: .rounded))
                    .frame(minWidth: size * 1.2)
                    .padding(.horizontal, size * 0.45)
                    .padding(.vertical, size * 0.22)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: size * 0.42, style: .continuous))
                    // The raised edge of a key, without a shadow (a shadow is drawn offscreen, for every key of the list)
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: size * 0.42, style: .continuous).fill(.black.opacity(0.3)).frame(height: 1).padding(.horizontal, 2)
                    }
                    .overlay(RoundedRectangle(cornerRadius: size * 0.42, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(KeyLabels.symbols(chord))
    }

    private var caps: [String] {
        var caps: [String] = []
        if chord.modifiers.contains(.control) { caps.append("⌃") }
        if chord.modifiers.contains(.option) { caps.append("⌥") }
        if chord.modifiers.contains(.shift) { caps.append("⇧") }
        if chord.modifiers.contains(.command) { caps.append("⌘") }
        caps.append(KeyLabels.label(chord.key))
        return caps
    }
}

/// A small colored tile with what the action does: an arrow, a workspace name, …
struct ActionIcon: View {
    let action: Action?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.gradient)
            switch action {
                case .workspace(let name), .moveWindowToWorkspace(let name):
                    Text(name)
                        .font(.system(size: name.count > 2 ? 9 : 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.5)
                        .padding(2)
                default:
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            }
            if case .moveWindowToWorkspace = action {
                Image(systemName: "arrow.down.right")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(2)
            }
        }
        .frame(width: 24, height: 24)
    }

    private var color: Color {
        switch action.map(ShortcutGroup.init(action:)) {
            case .windows: .blue
            case .workspaces: .teal
            case .layout: .purple
            case .other, nil: .gray
        }
    }

    private var symbol: String {
        switch action {
            case .focus(let direction): "arrow.\(direction.rawValue)"
            case .cycleFocus(let step): step == .next ? "arrow.forward.to.line" : "arrow.backward.to.line"
            case .focusBackAndForth: "arrow.uturn.backward.square"
            case .move(let direction): "arrow.\(direction.rawValue).square"
            case .swap: "arrow.left.arrow.right.square"
            case .joinWith: "rectangle.split.2x1"
            case .resize: "arrow.left.and.right"
            case .workspaceBackAndForth: "arrow.uturn.backward"
            case .moveWorkspaceToMonitor: "display.2"
            case .layout: "square.grid.2x2"
            case .workspaceLayout: "rectangle.split.3x1"
            case .fullscreen, .enterFullscreen: "arrow.up.left.and.arrow.down.right"
            case .exitFullscreen: "arrow.down.right.and.arrow.up.left"
            case .pin(let state): state == .off ? "pin.slash" : "pin"
            case .tileFloatingWindows: "rectangle.split.2x1"
            case .flattenWorkspaceTree: "arrow.triangle.2.circlepath"
            case .balanceSizes: "equal"
            case .closeWindow, .closeAllWindowsButCurrent: "xmark"
            case .enterMode: "switch.2"
            case .reloadSettings: "arrow.clockwise"
            case .moveMouse: "cursorarrow"
            case .custom: "terminal"
            case .workspace, .toggleWorkspace, .moveWindowToWorkspace, .moveWindowToWorkspaceAndFollow, nil: "questionmark"
        }
    }
}

/// Edits a shortcut in a popover: its keys and what it does
private struct ShortcutEditor: View {
    @Binding var shortcut: Settings.Shortcut
    @Binding var isRecording: Bool
    let modes: [String]
    let workspaces: [String]
    let remove: () -> Void

    var body: some View {
        Form {
            Section {
                HStack {
                    KeyCaps(chord: shortcut.chord, size: 16)
                    Spacer()
                    KeyChordRecorder(
                        chord: Binding(get: { shortcut.chord }, set: { if let chord = $0 { shortcut.chord = chord } }),
                        isRecording: $isRecording,
                    )
                }
            } header: {
                Text("Keys")
            }
            Section {
                ActionListEditor(actions: $shortcut.actions, modes: modes, workspaces: workspaces)
                Toggle("Repeat while the keys are held", isOn: Binding(get: { shortcut.repeats }, set: { shortcut.repeatsWhileHeld = $0 }))
                    .help("Like a key that types, with the key repeat of macOS. Shortcuts that resize the window repeat unless you turn it off")
            } header: {
                Text("Does")
            }
            Section {
                Button("Delete the shortcut", role: .destructive, action: remove)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Sections of the shortcut list, by what the first action does
private enum ShortcutGroup: CaseIterable, Identifiable {
    case windows, workspaces, layout, other

    var id: Self { self }

    var title: String {
        switch self {
            case .windows: "Windows"
            case .workspaces: "Workspaces"
            case .layout: "Layout"
            case .other: "Modes and more"
        }
    }

    init(_ shortcut: Settings.Shortcut) {
        self = shortcut.actions.first.map(ShortcutGroup.init(action:)) ?? .other
    }

    init(action: Action) {
        self = switch ActionKind(action) {
            case .focus, .cycleFocus, .focusBackAndForth, .move, .swap, .joinWith, .resize, .fullscreen, .pin, .closeWindow,
                 .closeAllWindowsButCurrent: .windows
            case .workspace, .workspaceBackAndForth, .moveWindowToWorkspace, .moveWorkspaceToMonitor: .workspaces
            case .workspaceLayout, .layout, .tileFloatingWindows, .flattenWorkspaceTree, .balanceSizes: .layout
            case .enterMode, .reloadSettings, .moveMouse, .custom: .other
        }
    }
}

extension Action {
    /// Orders actions of the same kind: directions in reading order, workspaces by name
    fileprivate var sortKey: String {
        switch self {
            case .focus(let direction), .move(let direction), .joinWith(let direction):
                "\(CardinalDirection.allCases.firstIndex(of: direction) ?? 0)"
            case .workspace(let name), .toggleWorkspace(let name), .moveWindowToWorkspace(let name), .moveWindowToWorkspaceAndFollow(let name),
                 .enterMode(let name): name
            default: commandLine
        }
    }
}

extension Action {
    /// For a list: e.g. "Focus left", "Go to workspace T"
    var summary: String {
        switch self {
            case .focus(let direction): "Focus \(direction.rawValue)"
            case .cycleFocus(let step): step == .next ? "Focus the next window" : "Focus the previous window"
            case .focusBackAndForth: "Focus the last focused window"
            case .move(let direction): "Move \(direction.rawValue)"
            case .swap(let direction): "Swap with the window \(direction == .left || direction == .right ? "on the \(direction.rawValue)" : direction == .up ? "above" : "below")"
            case .joinWith(let direction): "Join with \(direction.rawValue)"
            case .resize(let dimension, .add(let value)): "Grow \(dimension.rawValue) by \(value)"
            case .resize(let dimension, .subtract(let value)): "Shrink \(dimension.rawValue) by \(value)"
            case .resize(let dimension, .set(let value)): "Set \(dimension.rawValue) to \(value)"
            case .workspace(let name): "Go to workspace \(name)"
            case .toggleWorkspace(let name): "Go to workspace \(name), or back"
            case .workspaceBackAndForth: "Previous workspace"
            case .moveWindowToWorkspace(let name): "Move the window to workspace \(name)"
            case .moveWindowToWorkspaceAndFollow(let name): "Move the window to workspace \(name) and go there"
            case .moveWorkspaceToMonitor(let step, _): step == .next ? "Move the workspace to the next monitor" : "Move the workspace to the previous monitor"
            case .layout(let options): "Layout: " + options.map(\.rawValue).joined(separator: " / ")
            case .workspaceLayout(let layouts): "Workspace layout: " + layouts.map(\.rawValue).joined(separator: " / ")
            case .fullscreen(.marSpace): "Fullscreen"
            case .fullscreen(.macOSNative): "macOS fullscreen"
            case .enterFullscreen(.marSpace): "Enter fullscreen"
            case .enterFullscreen(.macOSNative): "Enter macOS fullscreen"
            case .exitFullscreen(.marSpace): "Exit fullscreen"
            case .exitFullscreen(.macOSNative): "Exit macOS fullscreen"
            case .pin(.toggle): "Pin or unpin the floating window"
            case .pin(.on): "Pin the floating window: on every workspace"
            case .pin(.off): "Unpin the window"
            case .tileFloatingWindows: "Tile all floating windows"
            case .flattenWorkspaceTree: "Reset the layout"
            case .balanceSizes: "Balance the sizes"
            case .closeWindow: "Close the window"
            case .closeAllWindowsButCurrent: "Close the other windows"
            case .enterMode(let name): "Switch to the \(name) mode"
            case .reloadSettings: "Reload the settings"
            case .moveMouse: "Move the mouse"
            case .custom(let line): line
        }
    }
}

// MARK: - Window rules

struct WindowRulesPane: View {
    @Bindable var model: SettingsModel
    @State fileprivate var editing: IdentifiedList<Settings.WindowRule>.ID? = nil
    /// The rule whose editor is open, as it was when it opened
    @State private var ruleBeforeEditing: Settings.WindowRule? = nil

    var body: some View {
        List {
            Section {
                ForEach(model.settings.windowRules.ids, id: \.self) { row($0) }
                    .onMove { source, destination in
                        model.store.update("Move Rule") { $0.windowRules.move(fromOffsets: source, toOffset: destination) }
                    }
                // A row, not the footer of the section: a footer of a list is one line, the end was cut off
                Text("Drag the rules to change their order. Click a rule to change it. Moving a window to a workspace with its shortcut makes it the rule of the app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowSeparator(.hidden, edges: .bottom)
            } header: {
                Text("When a window opens, the first rule that matches it runs")
            }
            Section {
                Button {
                    model.store.update("Add Rule") { $0.windowRules.append(Settings.WindowRule()) } // Does nothing until it has an action
                    editing = model.settings.windowRules.lastId
                } label: {
                    Label("Add a rule", systemImage: "plus")
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: editing) { previous, next in
            if let previous { finishEditing(previous) }
            ruleBeforeEditing = next.flatMap { model.settings.windowRules[id: $0] }
        }
        .onDisappear { // The settings window closes, or shows another pane, while the editor of a rule is open
            if let editing {
                finishEditing(editing)
                ruleBeforeEditing = model.settings.windowRules[id: editing]
            }
        }
    }

    /// A rule that was changed runs on the open windows that it matches: see ``SettingsStore/finishedEditing(windowRule:)``
    private func finishEditing(_ id: IdentifiedList<Settings.WindowRule>.ID) {
        guard let rule = model.settings.windowRules[id: id], rule != ruleBeforeEditing else { return }
        let store = model.store
        Task.startUnstructured { await store.finishedEditing(windowRule: id) }
    }
}

/// A rule in the list: the app (and the other conditions), then what happens
extension WindowRulesPane {
    @ViewBuilder
    private func row(_ id: IdentifiedList<Settings.WindowRule>.ID) -> some View {
        if let index = model.settings.windowRules.index(of: id) {
            WindowRuleRow(rule: model.settings.windowRules[index], hasProblem: !model.problems(at: "Window rules › \(index + 1)").isEmpty)
                .contentShape(Rectangle())
                .onTapGesture { editing = id }
                .popover(isPresented: Binding(get: { editing == id }, set: { if !$0 { editing = nil } }), arrowEdge: .trailing) {
                    // Built again while it closes, after the rule may have been removed
                    if model.settings.windowRules[id: id] != nil { editor(id) }
                }
        }
    }

    private func editor(_ id: IdentifiedList<Settings.WindowRule>.ID) -> some View {
        WindowRuleEditor(
            rule: $model.settings.windowRules.element(id, or: Settings.WindowRule()),
            problems: model.problems(at: "Window rules › \((model.settings.windowRules.index(of: id) ?? 0) + 1)"),
            modes: model.settings.modes.map(\.name),
            workspaces: model.settings.workspaces.persistent,
            remove: {
                editing = nil
                model.removing("Delete Rule", "Rule deleted") { $0.windowRules[id: id] = nil }
            },
        )
    }
}
private struct WindowRuleRow: View {
    let rule: Settings.WindowRule
    let hasProblem: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let bundleId = rule.condition.appBundleId {
                    Image(nsImage: AppCatalog.icon(of: bundleId)).resizable()
                } else {
                    Image(systemName: "macwindow").resizable().scaledToFit().foregroundStyle(.secondary).padding(2)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.condition.appBundleId.map(AppCatalog.name(of:)) ?? "Any app")
                if let conditions {
                    Text(conditions).font(.caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            if hasProblem {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack(spacing: 6) {
                if !rule.isComplete {
                    Text("Does nothing").font(.callout).foregroundStyle(.tertiary)
                }
                ForEach(Array(rule.actions.enumerated()), id: \.offset) { _, action in
                    HStack(spacing: 5) {
                        ActionIcon(action: action).scaleEffect(0.85)
                        Text(action.summary).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if rule.checkFurtherRules {
                    Image(systemName: "arrow.down.to.line").foregroundStyle(.tertiary).help("The next rules are checked too")
                }
            }
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var conditions: String? {
        let condition = rule.condition
        let parts = [
            condition.appBundleId.flatMap { AppCatalog.isInstalled($0) ? nil : "not installed" },
            condition.windowTitlePattern.map { "title contains \($0)" },
            condition.appNamePattern.map { "app name contains \($0)" },
            condition.workspace.map { "on workspace \($0)" },
            condition.duringStartup.map { $0 ? "while MarSpace starts" : "not while MarSpace starts" },
        ].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: ", ").capitalizingFirstLetter
    }
}

extension String {
    fileprivate var capitalizingFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}

/// Edits a rule in a popover
private struct WindowRuleEditor: View {
    @Binding var rule: Settings.WindowRule
    let problems: [SettingsProblem]
    let modes: [String]
    let workspaces: [String]
    let remove: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("App") { AppPicker(bundleId: $rule.condition.appBundleId) }
                if rule.condition.windowTitlePattern != nil {
                    OptionalTextRow(title: "Window title contains", placeholder: "Regular expression", value: $rule.condition.windowTitlePattern)
                }
                if rule.condition.appNamePattern != nil {
                    OptionalTextRow(title: "App name contains", placeholder: "Regular expression", value: $rule.condition.appNamePattern)
                }
                if rule.condition.workspace != nil {
                    OptionalTextRow(title: "On workspace", placeholder: "Workspace", value: $rule.condition.workspace)
                }
                if let duringStartup = rule.condition.duringStartup {
                    Toggle("Only while MarSpace starts", isOn: Binding(get: { duringStartup }, set: { rule.condition.duringStartup = $0 }))
                }
                Menu("Add a condition") {
                    Button("Window title") { rule.condition.windowTitlePattern = rule.condition.windowTitlePattern ?? "" }
                        .disabled(rule.condition.windowTitlePattern != nil)
                    Button("App name") { rule.condition.appNamePattern = rule.condition.appNamePattern ?? "" }
                        .disabled(rule.condition.appNamePattern != nil)
                    Button("Workspace") { rule.condition.workspace = rule.condition.workspace ?? (workspaces.first ?? "1") }
                        .disabled(rule.condition.workspace != nil)
                    Button("While MarSpace starts") { rule.condition.duringStartup = rule.condition.duringStartup ?? true }
                        .disabled(rule.condition.duringStartup != nil)
                }
                .fixedSize()
            } header: {
                Text("When a window opens")
            }
            Section {
                ActionListEditor(actions: $rule.actions, modes: modes, workspaces: workspaces, context: .event)
                Toggle("Check the next rules too", isOn: $rule.checkFurtherRules)
            } header: {
                Text("Then")
            } footer: {
                Text("When you close this, a changed rule also runs on the windows that are open.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !problems.isEmpty {
                Section {
                    ForEach(problems, id: \.message) { Label($0.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            Section {
                Button("Delete the rule", role: .destructive, action: remove).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A condition that can be removed: clearing it removes it
private struct OptionalTextRow: View {
    let title: String
    let placeholder: String
    @Binding var value: String?

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField("", text: Binding(get: { value ?? "" }, set: { value = $0 }), prompt: Text(placeholder))
                    .labelsHidden()
                    .frame(minWidth: 180)
                Button { value = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .help("Remove the condition")
            }
        }
    }
}

// MARK: - Workspaces

struct WorkspacesPane: View {
    @Binding var workspaces: Settings.Workspaces
    /// See ``SettingsModel/removing(_:_:)``
    let removing: (String, String, (inout Settings) -> Void) -> Void
    @State private var newName = ""

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(workspaces.persistent, id: \.self) { name in
                        WorkspaceChip(name: name) { removing("Remove Workspace", "Workspace \(name) removed") { $0.workspaces.persistent.removeAll { $0 == name } } }
                    }
                }
                .padding(.vertical, 4)
                HStack {
                    TextField("", text: $newName, prompt: Text("New workspace, e.g. Mail"))
                        .labelsHidden()
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Always there · \(workspaces.persistent.count)")
            } footer: {
                Text("These workspaces exist even when they are empty, in this order. Other workspaces come and go with their windows.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                ForEach(workspaces.monitorAssignments.ids, id: \.self) { id in
                    MonitorAssignmentRow(assignment: $workspaces.monitorAssignments.element(id, or: Settings.MonitorAssignment(workspace: "", monitors: []))) {
                        removing("Remove Monitor Assignment", "Monitor assignment removed") { $0.workspaces.monitorAssignments[id: id] = nil }
                    }
                }
                Button {
                    workspaces.monitorAssignments.append(Settings.MonitorAssignment(workspace: workspaces.persistent.first ?? "1", monitors: [.main]))
                } label: {
                    Label("Assign a workspace to a monitor", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Monitors")
            } footer: {
                Text("A workspace is shown on its monitor when it's connected.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !workspaces.persistent.contains(name) else { return }
        workspaces.persistent.append(name)
        newName = ""
    }
}

private struct WorkspaceChip: View {
    let name: String
    let remove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(name).font(.body.weight(.medium)).monospacedDigit()
            if isHovered {
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove the workspace")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minWidth: 36)
        .background(Color.teal.opacity(0.18), in: Capsule())
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.15), value: isHovered)
    }
}

private struct MonitorAssignmentRow: View {
    @Binding var assignment: Settings.MonitorAssignment
    let remove: () -> Void

    private enum Kind: Hashable { case main, secondary, number, name }

    var body: some View {
        HStack {
            TextField("", text: $assignment.workspace, prompt: Text("Workspace")).labelsHidden().frame(width: 90)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            let selector = assignment.monitors.first ?? .main
            Picker("", selection: Binding<Kind>(
                get: {
                    switch selector {
                        case .main: .main
                        case .secondary: .secondary
                        case .number: .number
                        case .nameMatching: .name
                    }
                },
                set: { kind in
                    let selector: MonitorSelector = switch kind {
                        case .main: .main
                        case .secondary: .secondary
                        case .number: .number(1)
                        case .name: .nameMatching("")
                    }
                    assignment.monitors = [selector]
                },
            )) {
                Text("Main monitor").tag(Kind.main)
                Text("Secondary monitor").tag(Kind.secondary)
                Text("Monitor number").tag(Kind.number)
                Text("Monitor named").tag(Kind.name)
            }
            .labelsHidden().fixedSize()
            switch selector {
                case .number(let number):
                    Stepper(value: Binding(get: { number }, set: { assignment.monitors = [.number(max(1, $0))] }), in: 1 ... 9) {
                        Text("\(number)").monospacedDigit()
                    }
                case .nameMatching(let pattern):
                    TextField("", text: Binding(get: { pattern }, set: { assignment.monitors = [.nameMatching($0)] }), prompt: Text("e.g. BenQ"))
                        .labelsHidden()
                case .main, .secondary:
                    EmptyView()
            }
            Spacer()
            Button(action: remove) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.borderless)
        }
    }
}

// MARK: - Automation

struct AutomationPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            automation("When MarSpace starts", \.afterStartup, "Automation › After startup")
            automation("When the focus changes", \.onFocusChanged, "Automation › Focus changed")
            automation("When the focused monitor changes", \.onFocusedMonitorChanged, "Automation › Focused monitor changed")
            automation("When the mode changes", \.onModeChanged, "Automation › Mode changed")
        }
        .formStyle(.grouped)
    }

    private func automation(_ title: String, _ keyPath: WritableKeyPath<Settings.Automation, IdentifiedList<Action>>, _ location: String) -> some View {
        Section(title) {
            ActionListEditor(
                actions: Binding(get: { model.settings.automation[keyPath: keyPath] }, set: { model.settings.automation[keyPath: keyPath] = $0 }),
                modes: model.settings.modes.map(\.name),
                workspaces: model.settings.workspaces.persistent,
                context: .event,
            )
            ForEach(model.problems(at: location), id: \.message) { problem in
                Label(problem.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Shared

private struct NameSheet: View {
    let title: String
    let placeholder: String
    @Binding var name: String
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("", text: $name, prompt: Text(placeholder)).frame(width: 260).onSubmit(confirm)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add", action: confirm).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func confirm() {
        done()
        dismiss()
    }
}
