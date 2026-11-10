import Common
import SwiftUI

// MARK: - Shortcuts

struct ShortcutsPane: View {
    @Bindable var model: SettingsModel
    @State private var modeName = mainModeId
    @State private var search = ""
    @State private var expanded: Set<Int> = []
    @State private var newModeName = ""
    @State private var isAddingMode = false

    private var modeIndex: Int? { model.settings.modes.firstIndex { $0.name == modeName } }
    private var keyNames: KeyNames { KeyNames(model.settings.general.keyboardLayout) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Picker("Mode", selection: $modeName) {
                        ForEach(model.settings.modes) { Text($0.name.capitalized).tag($0.name) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Button {
                        isAddingMode = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add a mode: a set of shortcuts that is active until a shortcut switches back")
                    if modeName != mainModeId {
                        Button(role: .destructive) {
                            model.settings.modes.removeAll { $0.name == modeName }
                            modeName = mainModeId
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Remove the mode")
                    }
                    Spacer()
                    TextField("", text: $search, prompt: Text("Search"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                }
            } footer: {
                Text(modeName == mainModeId
                    ? "Active normally. Click a shortcut to record another one, click the arrow to change what it does."
                    : "Active after a shortcut switches to the '\(modeName)' mode, until one switches back.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let modeIndex {
                let shortcuts = model.settings.modes[modeIndex].shortcuts
                ForEach(ShortcutGroup.allCases) { group in
                    let indices = displayed(shortcuts).filter { ShortcutGroup(shortcuts[$0]) == group }
                    if !indices.isEmpty {
                        Section("\(group.title) · \(indices.count)") {
                            ForEach(indices, id: \.self) { index in row(modeIndex, index) }
                        }
                    }
                }
                Section {
                    Button {
                        model.settings.modes[modeIndex].shortcuts.append(Settings.Shortcut(chord: KeyChord([.control, .option], .f1), actions: [.focus(.left)]))
                        expanded = [model.settings.modes[modeIndex].shortcuts.count - 1]
                    } label: {
                        Label("Add a shortcut", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .formStyle(.grouped)
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
        .onChange(of: modeName) { expanded = [] }
    }

    private func row(_ modeIndex: Int, _ index: Int) -> some View {
        ShortcutRow(
            shortcut: $model.settings.modes[modeIndex].shortcuts[index],
            isExpanded: Binding(
                get: { expanded.contains(index) },
                set: { if $0 { expanded.insert(index) } else { expanded.remove(index) } },
            ),
            keyNames: keyNames,
            isRecording: $model.isRecordingShortcut,
            problems: model.problems(at: "Shortcuts › \(modeName) › \(keyNames.notation(model.settings.modes[modeIndex].shortcuts[index].chord))"),
            modes: model.settings.modes.map(\.name),
            workspaces: model.settings.workspaces.persistent,
            remove: {
                model.settings.modes[modeIndex].shortcuts.remove(at: index)
                expanded = []
            },
        )
    }

    /// The matching shortcuts in a readable order: by action, then by parameter (directions in reading order, workspaces
    /// naturally sorted). The stored order doesn't change
    private func displayed(_ shortcuts: [Settings.Shortcut]) -> [Int] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return shortcuts.indices
            .filter { index in
                guard !query.isEmpty else { return true }
                let shortcut = shortcuts[index]
                return keyNames.notation(shortcut.chord).contains(query) || keyNames.symbols(shortcut.chord).lowercased().contains(query)
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
        self = switch shortcut.actions.first.map(ActionKind.init) {
            case .focus, .move, .joinWith, .resize, .fullscreen, .closeWindow, .closeAllWindowsButCurrent: .windows
            case .workspace, .workspaceBackAndForth, .moveWindowToWorkspace, .moveWorkspaceToMonitor: .workspaces
            case .layout, .flattenWorkspaceTree, .balanceSizes: .layout
            case .enterMode, .reloadSettings, .moveMouse, .custom, nil: .other
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

private struct ShortcutRow: View {
    @Binding var shortcut: Settings.Shortcut
    @Binding var isExpanded: Bool
    let keyNames: KeyNames
    @Binding var isRecording: Bool
    let problems: [SettingsProblem]
    let modes: [String]
    let workspaces: [String]
    let remove: () -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ActionListEditor(actions: $shortcut.actions, modes: modes, workspaces: workspaces)
            HStack {
                Spacer()
                Button("Remove the shortcut", role: .destructive, action: remove)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }
        } label: {
            HStack(spacing: 12) {
                KeyChordRecorder(
                    chord: Binding(get: { shortcut.chord }, set: { if let chord = $0 { shortcut.chord = chord } }),
                    keyNames: keyNames,
                    isRecording: $isRecording,
                )
                Text(summary)
                    .lineLimit(1)
                    .foregroundStyle(shortcut.actions.isEmpty ? .secondary : .primary)
                Spacer()
                if let problem = problems.first {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(problem.message)
                }
            }
        }
    }

    private var summary: String {
        shortcut.actions.isEmpty ? "Does nothing" : shortcut.actions.map(\.summary).joined(separator: ", then ")
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
