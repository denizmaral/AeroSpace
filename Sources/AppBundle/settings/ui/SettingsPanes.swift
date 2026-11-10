import Common
import SwiftUI

// MARK: - Shortcuts

struct ShortcutsPane: View {
    @Bindable var model: SettingsModel
    @State private var modeName = mainModeId
    @State private var search = ""
    @State private var editing: Int? = nil
    @State private var newModeName = ""
    @State private var isAddingMode = false

    private var modeIndex: Int? { model.settings.modes.firstIndex { $0.name == modeName } }

    var body: some View {
        Form {
            if let modeIndex {
                let shortcuts = model.settings.modes[modeIndex].shortcuts
                let displayed = displayed(shortcuts)
                ForEach(ShortcutGroup.allCases) { group in
                    let indices = displayed.filter { ShortcutGroup(shortcuts[$0]) == group }
                    if !indices.isEmpty {
                        Section {
                            ForEach(indices, id: \.self) { index in row(modeIndex, index) }
                        } header: {
                            Text(group.title)
                        }
                    }
                }
                if displayed.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
                Section {
                    Button {
                        model.settings.modes[modeIndex].shortcuts.append(Settings.Shortcut(chord: KeyChord([.control, .option], .f1), actions: [.focus(.left)]))
                        editing = model.settings.modes[modeIndex].shortcuts.count - 1
                    } label: {
                        Label("Add a shortcut", systemImage: "plus")
                    }
                } footer: {
                    Text(modeName == mainModeId
                        ? "Click a shortcut to change its keys or what it does."
                        : "Active after a shortcut switches to the \(modeName) mode, until one switches back.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .id(model.keyboardLayoutChanges) // The key labels follow the keyboard layout of macOS
        .searchable(text: $search, placement: .toolbar, prompt: "Search shortcuts")
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                Picker("Mode", selection: $modeName) {
                    ForEach(model.settings.modes) { Text($0.name.capitalized).tag($0.name) }
                }
                .pickerStyle(.segmented)
                .help("A mode is a set of shortcuts, active until a shortcut switches to another mode")
                Menu {
                    Button("New mode…") { isAddingMode = true }
                    if modeName != mainModeId {
                        Button("Remove the \(modeName.capitalized) mode", role: .destructive) {
                            model.settings.modes.removeAll { $0.name == modeName }
                            modeName = mainModeId
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
            }
        }
        .sheet(isPresented: $isAddingMode) {
            NameSheet(title: "New mode", placeholder: "e.g. resize", name: $newModeName) {
                let name = newModeName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !model.settings.modes.contains(where: { $0.name == name }) {
                    model.settings.modes.append(Settings.BindingMode(name: name, shortcuts: [
                        Settings.Shortcut(chord: KeyChord([], .escape), actions: [.enterMode(mainModeId)]),
                    ]))
                    modeName = name
                }
                newModeName = ""
            }
        }
        .onChange(of: modeName) { editing = nil }
    }

    private func row(_ modeIndex: Int, _ index: Int) -> some View {
        let shortcut = model.settings.modes[modeIndex].shortcuts[index]
        let keyNames = KeyNames(model.settings.general.keyboardLayout)
        return ShortcutRow(
            shortcut: shortcut,
            problem: model.problems(at: "Shortcuts › \(modeName) › \(keyNames.notation(shortcut.chord))").first,
        )
        .contentShape(Rectangle())
        .onTapGesture { editing = index }
        .popover(isPresented: Binding(get: { editing == index }, set: { if !$0 { editing = nil } }), arrowEdge: .trailing) {
            ShortcutEditor(
                shortcut: $model.settings.modes[modeIndex].shortcuts[index],
                isRecording: $model.isRecordingShortcut,
                modes: model.settings.modes.map(\.name),
                workspaces: model.settings.workspaces.persistent,
                remove: {
                    editing = nil
                    model.settings.modes[modeIndex].shortcuts.remove(at: index)
                },
            )
        }
    }

    /// The matching shortcuts in a readable order: by action, then by parameter (directions in reading order, workspaces
    /// naturally sorted). The stored order doesn't change
    private func displayed(_ shortcuts: [Settings.Shortcut]) -> [Int] {
        let keyNames = KeyNames(model.settings.general.keyboardLayout)
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return shortcuts.indices
            .filter { index in
                guard !query.isEmpty else { return true }
                let shortcut = shortcuts[index]
                return keyNames.notation(shortcut.chord).contains(query) || KeyLabels.symbols(shortcut.chord).lowercased().contains(query)
                    || shortcut.actions.contains { $0.summary.lowercased().contains(query) || $0.commandLine.lowercased().contains(query) }
            }
            .sorted { lhs, rhs in
                let (a, b) = (shortcuts[lhs].actions.first, shortcuts[rhs].actions.first)
                let (kindA, kindB) = (a.map { ActionKind.allCases.firstIndex(of: ActionKind($0)) ?? 0 } ?? .max, b.map { ActionKind.allCases.firstIndex(of: ActionKind($0)) ?? 0 } ?? .max)
                if kindA != kindB { return kindA < kindB }
                let (keyA, keyB) = (a?.sortKey ?? "", b?.sortKey ?? "")
                if keyA != keyB { return keyA.localizedStandardCompare(keyB) == .orderedAscending }
                return lhs < rhs
            }
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
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.42, style: .continuous)
                            .fill(.background.secondary)
                            .shadow(color: .black.opacity(0.35), radius: 0, y: 1),
                    )
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
            case .move(let direction): "arrow.\(direction.rawValue).square"
            case .joinWith: "rectangle.split.2x1"
            case .resize: "arrow.left.and.right"
            case .workspaceBackAndForth: "arrow.uturn.backward"
            case .moveWorkspaceToMonitor: "display.2"
            case .layout: "square.grid.2x2"
            case .fullscreen: "arrow.up.left.and.arrow.down.right"
            case .flattenWorkspaceTree: "arrow.triangle.2.circlepath"
            case .balanceSizes: "equal"
            case .closeWindow, .closeAllWindowsButCurrent: "xmark"
            case .enterMode: "switch.2"
            case .reloadSettings: "arrow.clockwise"
            case .moveMouse: "cursorarrow"
            case .custom: "terminal"
            case .workspace, .moveWindowToWorkspace, nil: "questionmark"
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
            case .focus, .move, .joinWith, .resize, .fullscreen, .closeWindow, .closeAllWindowsButCurrent: .windows
            case .workspace, .workspaceBackAndForth, .moveWindowToWorkspace, .moveWorkspaceToMonitor: .workspaces
            case .layout, .flattenWorkspaceTree, .balanceSizes: .layout
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
            case .workspace(let name), .moveWindowToWorkspace(let name), .enterMode(let name): name
            default: commandLine
        }
    }
}

extension Action {
    /// For a list: e.g. "Focus left", "Go to workspace T"
    var summary: String {
        switch self {
            case .focus(let direction): "Focus \(direction.rawValue)"
            case .move(let direction): "Move \(direction.rawValue)"
            case .joinWith(let direction): "Join with \(direction.rawValue)"
            case .resize(let dimension, .add(let value)): "Grow \(dimension.rawValue) by \(value)"
            case .resize(let dimension, .subtract(let value)): "Shrink \(dimension.rawValue) by \(value)"
            case .resize(let dimension, .set(let value)): "Set \(dimension.rawValue) to \(value)"
            case .workspace(let name): "Go to workspace \(name)"
            case .workspaceBackAndForth: "Previous workspace"
            case .moveWindowToWorkspace(let name): "Move the window to workspace \(name)"
            case .moveWorkspaceToMonitor(let step, _): step == .next ? "Move the workspace to the next monitor" : "Move the workspace to the previous monitor"
            case .layout(let options): "Layout: " + options.map(\.rawValue).joined(separator: " / ")
            case .fullscreen(.marSpace): "Fullscreen"
            case .fullscreen(.macOSNative): "macOS fullscreen"
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

    var body: some View {
        Form {
            Section {
                Text("When a window opens, the first rule that matches it runs its actions, e.g. Terminal goes to workspace T.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.settings.windowRules.indices, id: \.self) { index in
                WindowRuleSection(
                    rule: $model.settings.windowRules[index],
                    problems: model.problems(at: "Window rules › \(index + 1)"),
                    modes: model.settings.modes.map(\.name),
                    workspaces: model.settings.workspaces.persistent,
                    canMoveUp: index > 0,
                    canMoveDown: index < model.settings.windowRules.count - 1,
                    move: { offset in model.settings.windowRules.swapAt(index, index + offset) },
                    remove: { model.settings.windowRules.remove(at: index) },
                )
            }
            Section {
                Button {
                    model.settings.windowRules.append(Settings.WindowRule(actions: [.moveWindowToWorkspace(model.settings.workspaces.persistent.first ?? "1")]))
                } label: {
                    Label("Add a rule", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
    }
}

private struct WindowRuleSection: View {
    @Binding var rule: Settings.WindowRule
    let problems: [SettingsProblem]
    let modes: [String]
    let workspaces: [String]
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        Section {
            LabeledContent("When") { AppPicker(bundleId: $rule.condition.appBundleId) }
            if rule.condition.windowTitlePattern != nil {
                OptionalTextRow(title: "and the window title contains", placeholder: "Regular expression", value: $rule.condition.windowTitlePattern)
            }
            if rule.condition.appNamePattern != nil {
                OptionalTextRow(title: "and the app name contains", placeholder: "Regular expression", value: $rule.condition.appNamePattern)
            }
            if rule.condition.workspace != nil {
                OptionalTextRow(title: "and the workspace is", placeholder: "Workspace", value: $rule.condition.workspace)
            }
            if let duringStartup = rule.condition.duringStartup {
                Toggle("and MarSpace is starting", isOn: Binding(get: { duringStartup }, set: { rule.condition.duringStartup = $0 }))
            }
            ActionListEditor(actions: $rule.actions, modes: modes, workspaces: workspaces)
            Toggle("Check the next rules too", isOn: $rule.checkFurtherRules)
            ForEach(problems, id: \.message) { problem in
                Label(problem.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } header: {
            HStack {
                Text(rule.condition.appBundleId.map { "\(AppPicker.name(of: $0)) opens a window" } ?? "A window opens")
                Spacer()
                Menu {
                    Button("Window title") { rule.condition.windowTitlePattern = rule.condition.windowTitlePattern ?? "" }
                        .disabled(rule.condition.windowTitlePattern != nil)
                    Button("App name") { rule.condition.appNamePattern = rule.condition.appNamePattern ?? "" }
                        .disabled(rule.condition.appNamePattern != nil)
                    Button("Workspace") { rule.condition.workspace = rule.condition.workspace ?? (workspaces.first ?? "1") }
                        .disabled(rule.condition.workspace != nil)
                    Button("While MarSpace starts") { rule.condition.duringStartup = rule.condition.duringStartup ?? true }
                        .disabled(rule.condition.duringStartup != nil)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a condition")
                Button { move(-1) } label: { Image(systemName: "chevron.up") }.disabled(!canMoveUp).help("Check it earlier")
                Button { move(1) } label: { Image(systemName: "chevron.down") }.disabled(!canMoveDown).help("Check it later")
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }.help("Remove the rule")
            }
            .buttonStyle(.borderless)
        }
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
    @State private var newName = ""

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(workspaces.persistent, id: \.self) { name in
                        WorkspaceChip(name: name) { workspaces.persistent.removeAll { $0 == name } }
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
                ForEach(workspaces.monitorAssignments.indices, id: \.self) { index in
                    MonitorAssignmentRow(assignment: $workspaces.monitorAssignments[index]) {
                        workspaces.monitorAssignments.remove(at: index)
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

    private func automation(_ title: String, _ keyPath: WritableKeyPath<Settings.Automation, [Action]>, _ location: String) -> some View {
        Section(title) {
            ActionListEditor(
                actions: Binding(get: { model.settings.automation[keyPath: keyPath] }, set: { model.settings.automation[keyPath: keyPath] = $0 }),
                modes: model.settings.modes.map(\.name),
                workspaces: model.settings.workspaces.persistent,
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
