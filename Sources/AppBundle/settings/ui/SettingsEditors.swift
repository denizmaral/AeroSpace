import AppKit
import Common
import HotKey
import SwiftUI

// MARK: - Actions

/// Edits a list of actions that run one after the other
struct ActionListEditor: View {
    @Binding var actions: [Action]
    let modes: [String]
    let workspaces: [String]

    var body: some View {
        ForEach(actions.indices, id: \.self) { index in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if actions.count > 1 {
                    Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                }
                ActionEditor(action: $actions[index], modes: modes, workspaces: workspaces)
                Button {
                    actions.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove the action")
            }
        }
        Button {
            actions.append(.focus(.left))
        } label: {
            Label(actions.isEmpty ? "Add an action" : "Add another action", systemImage: "plus.circle")
        }
        .buttonStyle(.borderless)
    }
}

/// The kind of an action, for the picker. Each kind has the parameters of its action
enum ActionKind: String, CaseIterable, Identifiable {
    case focus, move, joinWith, resize
    case workspace, workspaceBackAndForth, moveWindowToWorkspace, moveWorkspaceToMonitor
    case layout, fullscreen, flattenWorkspaceTree, balanceSizes
    case closeWindow, closeAllWindowsButCurrent
    case enterMode, reloadSettings, moveMouse, custom

    var id: Self { self }

    var title: String {
        switch self {
            case .focus: "Focus a window"
            case .move: "Move the window"
            case .joinWith: "Join with a window"
            case .resize: "Resize the window"
            case .workspace: "Go to a workspace"
            case .workspaceBackAndForth: "Go to the previous workspace"
            case .moveWindowToWorkspace: "Move the window to a workspace"
            case .moveWorkspaceToMonitor: "Move the workspace to a monitor"
            case .layout: "Change the layout"
            case .fullscreen: "Fullscreen"
            case .flattenWorkspaceTree: "Reset the layout of the workspace"
            case .balanceSizes: "Balance the window sizes"
            case .closeWindow: "Close the window"
            case .closeAllWindowsButCurrent: "Close the other windows"
            case .enterMode: "Switch to a mode"
            case .reloadSettings: "Reload the settings"
            case .moveMouse: "Move the mouse"
            case .custom: "Custom command…"
        }
    }

    /// Separators in the menu
    static let groups: [[ActionKind]] = [
        [.focus, .move, .joinWith, .resize],
        [.workspace, .workspaceBackAndForth, .moveWindowToWorkspace, .moveWorkspaceToMonitor],
        [.layout, .fullscreen, .flattenWorkspaceTree, .balanceSizes],
        [.closeWindow, .closeAllWindowsButCurrent],
        [.enterMode, .moveMouse], // Settings apply right away: reloading them is only kept for existing shortcuts
        [.custom],
    ]

    init(_ action: Action) {
        self = switch action {
            case .focus: .focus
            case .move: .move
            case .joinWith: .joinWith
            case .resize: .resize
            case .workspace: .workspace
            case .workspaceBackAndForth: .workspaceBackAndForth
            case .moveWindowToWorkspace: .moveWindowToWorkspace
            case .moveWorkspaceToMonitor: .moveWorkspaceToMonitor
            case .layout: .layout
            case .fullscreen: .fullscreen
            case .flattenWorkspaceTree: .flattenWorkspaceTree
            case .balanceSizes: .balanceSizes
            case .closeWindow: .closeWindow
            case .closeAllWindowsButCurrent: .closeAllWindowsButCurrent
            case .enterMode: .enterMode
            case .reloadSettings: .reloadSettings
            case .moveMouse: .moveMouse
            case .custom: .custom
        }
    }

    /// The action of the kind with sensible parameters. A custom command starts with the command line of the previous action
    func defaultAction(previous: Action, mode: String, workspace: String) -> Action {
        switch self {
            case .focus: .focus(.left)
            case .move: .move(.left)
            case .joinWith: .joinWith(.left)
            case .resize: .resize(.smart, .add(50))
            case .workspace: .workspace(workspace)
            case .workspaceBackAndForth: .workspaceBackAndForth
            case .moveWindowToWorkspace: .moveWindowToWorkspace(workspace)
            case .moveWorkspaceToMonitor: .moveWorkspaceToMonitor(.next, wrapAround: true)
            case .layout: .layout([.tiles, .accordion])
            case .fullscreen: .fullscreen(.marSpace)
            case .flattenWorkspaceTree: .flattenWorkspaceTree
            case .balanceSizes: .balanceSizes
            case .closeWindow: .closeWindow
            case .closeAllWindowsButCurrent: .closeAllWindowsButCurrent
            case .enterMode: .enterMode(mode)
            case .reloadSettings: .reloadSettings
            case .moveMouse: .moveMouse(.windowLazyCenter)
            case .custom: .custom(previous.commandLine)
        }
    }
}

/// One action: what it does, and its parameters right next to it
struct ActionEditor: View {
    @Binding var action: Action
    let modes: [String]
    let workspaces: [String]

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(ActionKind.groups.indices, id: \.self) { group in
                    if group > 0 { Divider() }
                    ForEach(ActionKind.groups[group]) { kind in
                        Button(kind.title) {
                            action = kind.defaultAction(previous: action, mode: modes.first ?? mainModeId, workspace: workspaces.first ?? "1")
                        }
                    }
                }
            } label: {
                Text(ActionKind(action).title)
            }
            .fixedSize()
            parameters
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var parameters: some View {
        switch action {
            case .focus(let direction): DirectionPicker(direction: direction) { action = .focus($0) }
            case .move(let direction): DirectionPicker(direction: direction) { action = .move($0) }
            case .joinWith(let direction): DirectionPicker(direction: direction) { action = .joinWith($0) }
            case .resize(let dimension, let amount): ResizeEditor(dimension: dimension, amount: amount) { action = .resize($0, $1) }
            case .workspace(let name): WorkspaceField(name: name, workspaces: workspaces) { action = .workspace($0) }
            case .moveWindowToWorkspace(let name): WorkspaceField(name: name, workspaces: workspaces) { action = .moveWindowToWorkspace($0) }
            case .moveWorkspaceToMonitor(let step, let wrapAround):
                Picker("", selection: Binding(get: { step }, set: { action = .moveWorkspaceToMonitor($0, wrapAround: wrapAround) })) {
                    Text("Next").tag(Action.MonitorStep.next)
                    Text("Previous").tag(Action.MonitorStep.prev)
                }
                .labelsHidden().fixedSize()
                Toggle("Wrap around", isOn: Binding(get: { wrapAround }, set: { action = .moveWorkspaceToMonitor(step, wrapAround: $0) }))
            case .layout(let options): LayoutOptionsEditor(options: options) { action = .layout($0) }
            case .fullscreen(let kind):
                Picker("", selection: Binding(get: { kind }, set: { action = .fullscreen($0) })) {
                    Text("MarSpace").tag(Action.FullscreenKind.marSpace)
                    Text("macOS").tag(Action.FullscreenKind.macOSNative)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("MarSpace: the window fills its workspace. macOS: the window gets its own Space, like the green button")
            case .enterMode(let name):
                Picker("", selection: Binding(get: { name }, set: { action = .enterMode($0) })) {
                    ForEach(Set(modes + [name]).sorted(), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().fixedSize()
            case .moveMouse(let target):
                Picker("", selection: Binding(get: { target }, set: { action = .moveMouse($0) })) {
                    Text("To the center of the window").tag(MouseTarget.windowLazyCenter)
                    Text("To the center of the window, always").tag(MouseTarget.windowForceCenter)
                    Text("To the center of the monitor").tag(MouseTarget.monitorLazyCenter)
                    Text("To the center of the monitor, always").tag(MouseTarget.monitorForceCenter)
                }
                .labelsHidden().fixedSize()
            case .custom(let line): CustomCommandField(line: line) { action = .custom($0) }
            case .workspaceBackAndForth, .flattenWorkspaceTree, .balanceSizes, .closeWindow, .closeAllWindowsButCurrent, .reloadSettings:
                EmptyView()
        }
    }
}

private struct DirectionPicker: View {
    let direction: CardinalDirection
    let set: @MainActor (CardinalDirection) -> Void

    var body: some View {
        Picker("", selection: Binding(get: { direction }, set: set)) {
            Image(systemName: "arrow.left").tag(CardinalDirection.left).help("Left")
            Image(systemName: "arrow.down").tag(CardinalDirection.down).help("Down")
            Image(systemName: "arrow.up").tag(CardinalDirection.up).help("Up")
            Image(systemName: "arrow.right").tag(CardinalDirection.right).help("Right")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

private struct ResizeEditor: View {
    let dimension: ResizeCmdArgs.Dimension
    let amount: Action.ResizeAmount
    let set: @MainActor (ResizeCmdArgs.Dimension, Action.ResizeAmount) -> Void

    private enum Sign: Hashable { case add, subtract, set }

    var body: some View {
        Picker("", selection: Binding(get: { dimension }, set: { set($0, amount) })) {
            Text("Smart").tag(ResizeCmdArgs.Dimension.smart)
            Text("Smart, other side").tag(ResizeCmdArgs.Dimension.smartOpposite)
            Text("Width").tag(ResizeCmdArgs.Dimension.width)
            Text("Height").tag(ResizeCmdArgs.Dimension.height)
        }
        .labelsHidden().fixedSize()
        let (sign, value): (Sign, UInt) = switch amount {
            case .add(let value): (.add, value)
            case .subtract(let value): (.subtract, value)
            case .set(let value): (.set, value)
        }
        Picker("", selection: Binding(get: { sign }, set: { set(dimension, Self.amount($0, value)) })) {
            Text("Grow").tag(Sign.add)
            Text("Shrink").tag(Sign.subtract)
            Text("Set").tag(Sign.set)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        TextField("", value: Binding(get: { Int(value) }, set: { set(dimension, Self.amount(sign, UInt(max(0, $0)))) }), format: .number)
            .frame(width: 56)
            .multilineTextAlignment(.trailing)
        Text("pt").foregroundStyle(.secondary)
    }

    private static func amount(_ sign: Sign, _ value: UInt) -> Action.ResizeAmount {
        switch sign {
            case .add: .add(value)
            case .subtract: .subtract(value)
            case .set: .set(value)
        }
    }
}

/// The layouts that the action cycles through, in this order
private struct LayoutOptionsEditor: View {
    let options: [Action.LayoutOption]
    let set: @MainActor ([Action.LayoutOption]) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Action.LayoutOption.allCases, id: \.self) { option in
                Toggle(option.rawValue.capitalized, isOn: Binding(
                    get: { options.contains(option) },
                    set: { isOn in set(isOn ? options + [option] : options.filter { $0 != option }) },
                ))
                .toggleStyle(.button)
                .controlSize(.small)
            }
        }
        .help("Each time, the next of the selected layouts")
    }
}

/// A workspace name: one of the known workspaces, or a new one
struct WorkspaceField: View {
    let name: String
    let workspaces: [String]
    let set: @MainActor (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            TextField("", text: Binding(get: { name }, set: { set($0.trimmingCharacters(in: .whitespaces)) }), prompt: Text("Workspace"))
                .labelsHidden()
                .frame(width: 80)
            Menu {
                ForEach(workspaces, id: \.self) { workspace in Button(workspace) { set(workspace) } }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(workspaces.isEmpty)
        }
    }
}

/// Any command line, checked as it's typed
private struct CustomCommandField: View {
    let line: String
    let set: @MainActor (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("", text: Binding(get: { line }, set: set), prompt: Text("e.g. exec-and-forget open -a Terminal"))
                .labelsHidden()
                .font(.body.monospaced())
            if let problem = Self.problem(line) {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @MainActor
    private static func problem(_ line: String) -> String? {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return "Type a command" }
        return switch parseCommand(line, allowExecAndForget: true, allowEval: false) {
            case .cmd: nil
            case .help: "This shows the help of the command"
            case .failure(let failure): failure.msg.components(separatedBy: "\n").first
        }
    }
}

// MARK: - Keys

/// Shows a key chord and records a new one: click, then type the shortcut. Esc cancels
struct KeyChordRecorder: View {
    @Binding var chord: KeyChord?
    @Binding var isRecording: Bool
    @State private var monitor: Any? = nil

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Group {
                if monitor != nil {
                    Label("Press the keys…", systemImage: "record.circle").foregroundStyle(.tint)
                } else {
                    Label("Record new keys", systemImage: "keyboard")
                }
            }
            .frame(minWidth: 140)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(monitor != nil ? Color.accentColor : .clear))
        }
        .buttonStyle(.plain)
        .help("Click, then type the shortcut. Esc cancels")
        .onDisappear(perform: stop)
    }

    private func start() {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, event.modifierFlags.isDisjoint(with: .deviceIndependentFlagsMask) { // Esc
                stop()
                return nil
            }
            if let key = Key(carbonKeyCode: UInt32(event.keyCode)) {
                chord = KeyChord(KeyChord.Modifiers(event.modifierFlags), key)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}


// MARK: - Apps

/// An app: picked from the running apps (with its icon and name), or its bundle id typed
struct AppPicker: View {
    @Binding var bundleId: String?
    @State private var isTyping = false

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(AppCatalog.runningApps, id: \.bundleId) { app in
                    Button {
                        bundleId = app.bundleId
                        isTyping = false
                    } label: {
                        Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                    }
                }
                Divider()
                Button("Type a bundle id…") { isTyping = true }
                if bundleId != nil {
                    Button("Any app") { bundleId = nil }
                }
            } label: {
                if let bundleId {
                    Label { Text(AppCatalog.name(of: bundleId)) } icon: { Image(nsImage: AppCatalog.icon(of: bundleId)) }
                } else {
                    Text("Any app")
                }
            }
            .fixedSize()
            if isTyping {
                TextField("", text: Binding(get: { bundleId ?? "" }, set: { bundleId = $0.isEmpty ? nil : $0 }), prompt: Text("com.example.App"))
                    .labelsHidden()
                    .frame(minWidth: 180)
            } else if let bundleId {
                Text(bundleId).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

/// Names and icons of apps. Asking Launch Services is slow and an app icon holds all its sizes (up to 1024 px): each icon
/// is drawn once into a small bitmap, names and icons are cached, the running apps are listed at most every 2 seconds
@MainActor
enum AppCatalog {
    struct App {
        let bundleId: String
        let name: String
        let icon: NSImage
    }

    private static var names: [String: String] = [:]
    private static var icons: [String: NSImage] = [:]
    private static var running: (date: Date, apps: [App])? = nil

    static func name(of bundleId: String) -> String {
        if let name = names[bundleId] { return name }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            .map { FileManager.default.displayName(atPath: $0.path).replacing(".app", with: "") } ?? bundleId
        names[bundleId] = name
        return name
    }

    static func icon(of bundleId: String) -> NSImage {
        if let icon = icons[bundleId] { return icon }
        let source = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId).map { NSWorkspace.shared.icon(forFile: $0.path) }
        let icon = thumbnail(source ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage())
        icons[bundleId] = icon
        return icon
    }

    static var runningApps: [App] {
        if let running, running.date.timeIntervalSinceNow > -2 { return running.apps }
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> App? in
                guard let bundleId = app.bundleIdentifier else { return nil }
                return App(bundleId: bundleId, name: app.localizedName ?? name(of: bundleId), icon: icon(of: bundleId))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        running = (Date(), apps)
        return apps
    }

    /// 16 pt (32 px for Retina): the only size shown
    private static func thumbnail(_ image: NSImage) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        return NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
    }
}
