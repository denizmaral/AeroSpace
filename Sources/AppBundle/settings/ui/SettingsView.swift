import Common
import SwiftUI

/// The settings window: everything the user can configure, nothing to type into a file
struct SettingsView: View {
    @Bindable var model: SettingsModel
    @State private var pane: SettingsPane? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { pane in
                Label { Text(pane.title) } icon: { SettingsIconTile(symbol: pane.symbol, color: pane.color) }
                    .badge(model.problems(at: pane.problemLocation).count)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            SettingsPaneView(model: model, pane: pane ?? .general)
                .navigationTitle((pane ?? .general).title)
        }
        .frame(minWidth: 820, minHeight: 580)
    }
}

struct SettingsPaneView: View {
    @Bindable var model: SettingsModel
    let pane: SettingsPane

    var body: some View {
        switch pane {
            case .general: GeneralPane(general: $model.settings.general)
            case .appearance: AppearancePane(appearance: $model.settings.appearance)
            case .shortcuts: ShortcutsPane(model: model)
            case .windowRules: WindowRulesPane(model: model)
            case .workspaces: WorkspacesPane(workspaces: $model.settings.workspaces)
            case .automation: AutomationPane(model: model)
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, shortcuts, windowRules, workspaces, automation

    var id: Self { self }

    var title: String {
        switch self {
            case .general: "General"
            case .appearance: "Appearance"
            case .shortcuts: "Shortcuts"
            case .windowRules: "Window Rules"
            case .workspaces: "Workspaces"
            case .automation: "Automation"
        }
    }

    var symbol: String {
        switch self {
            case .general: "gearshape.fill"
            case .appearance: "paintbrush.pointed.fill"
            case .shortcuts: "command"
            case .windowRules: "macwindow.badge.plus"
            case .workspaces: "square.grid.2x2.fill"
            case .automation: "bolt.fill"
        }
    }

    var color: Color {
        switch self {
            case .general: .gray
            case .appearance: .purple
            case .shortcuts: .blue
            case .windowRules: .orange
            case .workspaces: .teal
            case .automation: .pink
        }
    }

    /// The prefix of ``SettingsProblem/location`` for the problems of the pane
    var problemLocation: String {
        switch self {
            case .general, .appearance: "-"
            case .shortcuts: "Shortcuts"
            case .windowRules: "Window rules"
            case .workspaces: "Workspaces"
            case .automation: "Automation"
        }
    }
}

/// The colored rounded square with a white symbol, like in System Settings
struct SettingsIconTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Binding var general: Settings.General

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $general.focusFollowsMouse) {
                    Text("Focus follows the mouse")
                    Text("A window gets the focus when the mouse enters it")
                }
                Toggle(isOn: $general.startAtLogin) {
                    Text("Open at login")
                }
                Toggle(isOn: $general.automaticallyUnhideMacosHiddenApps) {
                    Text("Unhide hidden apps")
                    Text("Apps hidden with ⌘H come back right away, their windows keep their places")
                }
            }

            Section("New windows") {
                HStack(spacing: 12) {
                    ForEach(NewWindowPlacement.allCases, id: \.self) { placement in
                        PlacementCard(placement: placement, isSelected: general.newWindowPlacement == placement) {
                            general.newWindowPlacement = placement
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Layout") {
                Picker("Workspace layout", selection: $general.defaultRootLayout) {
                    Text("Tiles").tag(Layout.tiles)
                    Text("Accordion").tag(Layout.accordion)
                }
                .pickerStyle(.segmented)
                Picker("Orientation", selection: $general.defaultRootOrientation) {
                    Text("Automatic").tag(DefaultContainerOrientation.auto)
                    Text("Horizontal").tag(DefaultContainerOrientation.horizontal)
                    Text("Vertical").tag(DefaultContainerOrientation.vertical)
                }
                LabeledContent("Accordion padding") {
                    ValueSlider(value: $general.accordionPadding, range: 0 ... 100, unit: "pt")
                }
                DisclosureGroup("Tree normalization") {
                    Toggle("Merge containers with a single window", isOn: $general.flattenContainers)
                    Toggle("Alternate the orientation of nested containers", isOn: $general.oppositeOrientationForNestedContainers)
                }
            }

            Section {
                Picker("Keyboard layout", selection: $general.keyboardLayout) {
                    Text("QWERTY").tag(KeyMapping.Preset.qwerty)
                    Text("Dvorak").tag(KeyMapping.Preset.dvorak)
                    Text("Colemak").tag(KeyMapping.Preset.colemak)
                }
            } footer: {
                Text("How the keys of the shortcuts are named. Shortcuts keep their physical keys.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

extension NewWindowPlacement: CaseIterable {
    static let allCases: [NewWindowPlacement] = [.dwindle, .balanced, .i3]

    var title: String {
        switch self {
            case .dwindle: "Split the focused window"
            case .balanced: "Split the largest window"
            case .i3: "Next to the focused window"
        }
    }
}

/// A choice of new window placement, with a diagram of where the new window goes
private struct PlacementCard: View {
    let placement: NewWindowPlacement
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 8) {
                diagram
                    .frame(height: 64)
                    .padding(8)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(placement.title)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The existing windows in gray, the new window in the accent color
    @ViewBuilder
    private var diagram: some View {
        let old = RoundedRectangle(cornerRadius: 3, style: .continuous).fill(.secondary.opacity(0.35))
        let new = RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.accentColor.opacity(0.85))
        HStack(spacing: 3) {
            switch placement {
                case .dwindle:
                    old
                    VStack(spacing: 3) {
                        old
                        new
                    }
                case .balanced:
                    VStack(spacing: 3) {
                        old
                        new
                    }
                    old
                case .i3:
                    old
                    old
                    new
            }
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @Binding var appearance: Settings.Appearance
    @State private var linksScreenEdges = true

    var body: some View {
        Form {
            Section {
                LayoutPreview(appearance: appearance)
                    .frame(height: 170)
                    .listRowInsets(EdgeInsets())
            }

            Section("Gaps") {
                LabeledContent("Between windows") {
                    ValueSlider(value: Binding(
                        get: { appearance.gaps.innerHorizontal },
                        set: { appearance.gaps.innerHorizontal = $0; appearance.gaps.innerVertical = $0 },
                    ), range: 0 ... 60, unit: "pt")
                }
                Toggle("Same gap at every screen edge", isOn: $linksScreenEdges)
                if linksScreenEdges {
                    LabeledContent("Screen edges") {
                        ValueSlider(value: Binding(
                            get: { appearance.gaps.outerTop },
                            set: { value in
                                appearance.gaps.outerTop = value
                                appearance.gaps.outerBottom = value
                                appearance.gaps.outerLeft = value
                                appearance.gaps.outerRight = value
                            },
                        ), range: 0 ... 60, unit: "pt")
                    }
                } else {
                    LabeledContent("Top") { ValueSlider(value: $appearance.gaps.outerTop, range: 0 ... 60, unit: "pt") }
                    LabeledContent("Bottom") { ValueSlider(value: $appearance.gaps.outerBottom, range: 0 ... 60, unit: "pt") }
                    LabeledContent("Left") { ValueSlider(value: $appearance.gaps.outerLeft, range: 0 ... 60, unit: "pt") }
                    LabeledContent("Right") { ValueSlider(value: $appearance.gaps.outerRight, range: 0 ... 60, unit: "pt") }
                }
            }

            Section("Focus border") {
                Toggle("Show a border around the focused window", isOn: $appearance.focusBorder.isEnabled)
                if appearance.focusBorder.isEnabled {
                    BorderColorEditor(color: $appearance.focusBorder.color)
                    LabeledContent("Width") { ValueSlider(value: $appearance.focusBorder.width, range: 1 ... 20, unit: "pt") }
                    LabeledContent("Corner radius") { ValueSlider(value: $appearance.focusBorder.radius, range: 0 ... 50, unit: "pt") }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let gaps = appearance.gaps
            linksScreenEdges = Set([gaps.outerTop, gaps.outerBottom, gaps.outerLeft, gaps.outerRight]).count == 1
        }
    }
}

private struct BorderColorEditor: View {
    @Binding var color: BorderColor

    private enum Style: Hashable { case solid, gradient }

    var body: some View {
        Picker("Color", selection: Binding<Style>(
            get: { if case .solid = color { .solid } else { .gradient } },
            set: { style in
                switch (style, color) {
                    case (.solid, .gradient(let start, _, _)): color = .solid(start)
                    case (.gradient, .solid(let solid)): color = .gradient(start: solid, end: ARGB(0xEE00_FF99), direction: .topLeftToBottomRight)
                    default: break
                }
            },
        )) {
            Text("Solid").tag(Style.solid)
            Text("Gradient").tag(Style.gradient)
        }
        .pickerStyle(.segmented)
        switch color {
            case .solid(let value):
                ColorPicker("Border color", selection: argbBinding(value) { color = .solid($0) }, supportsOpacity: true)
            case .gradient(let start, let end, let direction):
                ColorPicker("From", selection: argbBinding(start) { color = .gradient(start: $0, end: end, direction: direction) }, supportsOpacity: true)
                ColorPicker("To", selection: argbBinding(end) { color = .gradient(start: start, end: $0, direction: direction) }, supportsOpacity: true)
                Picker("Direction", selection: Binding(
                    get: { direction },
                    set: { color = .gradient(start: start, end: end, direction: $0) },
                )) {
                    Label("Top left to bottom right", systemImage: "arrow.down.right").tag(BorderColor.GradientDirection.topLeftToBottomRight)
                    Label("Top right to bottom left", systemImage: "arrow.down.left").tag(BorderColor.GradientDirection.topRightToBottomLeft)
                }
        }
    }

    private func argbBinding(_ value: ARGB, set: @escaping (ARGB) -> Void) -> Binding<Color> {
        Binding(get: { value.color }, set: { set(ARGB($0)) })
    }
}

/// A desktop with three windows: the gaps and the focus border as they are set
private struct LayoutPreview: View {
    let appearance: Settings.Appearance

    var body: some View {
        GeometryReader { geometry in
            // A 1440 pt wide screen, scaled to the preview
            let scale = geometry.size.width / 1440
            let gaps = appearance.gaps
            let inner = CGFloat(gaps.innerHorizontal) * scale
            let innerVertical = CGFloat(gaps.innerVertical) * scale
            ZStack {
                LinearGradient(colors: [.indigo.opacity(0.55), .teal.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack(spacing: inner) {
                    MockWindow(border: appearance.focusBorder, scale: scale, isFocused: true)
                    VStack(spacing: innerVertical) {
                        MockWindow(border: appearance.focusBorder, scale: scale, isFocused: false)
                        MockWindow(border: appearance.focusBorder, scale: scale, isFocused: false)
                    }
                }
                .padding(.top, CGFloat(gaps.outerTop) * scale)
                .padding(.bottom, CGFloat(gaps.outerBottom) * scale)
                .padding(.leading, CGFloat(gaps.outerLeft) * scale)
                .padding(.trailing, CGFloat(gaps.outerRight) * scale)
            }
        }
        .animation(.snappy, value: appearance)
        .accessibilityLabel("Preview of the gaps and the focus border")
    }
}

private struct MockWindow: View {
    let border: Settings.Appearance.FocusBorder
    let scale: CGFloat
    let isFocused: Bool

    var body: some View {
        let radius = CGFloat(border.radius) * scale
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.background)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 3) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 5, height: 5) }
                }
                .padding(6)
            }
            .overlay {
                if isFocused && border.isEnabled {
                    let width = max(1, CGFloat(border.width) * scale)
                    RoundedRectangle(cornerRadius: radius + width / 2, style: .continuous)
                        .strokeBorder(border.color.style, lineWidth: width)
                        .padding(-width)
                }
            }
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }
}

extension BorderColor {
    var style: AnyShapeStyle {
        switch self {
            case .solid(let color): AnyShapeStyle(color.color)
            case .gradient(let start, let end, let direction):
                AnyShapeStyle(LinearGradient(
                    colors: [start.color, end.color],
                    startPoint: direction == .topLeftToBottomRight ? .topLeading : .topTrailing,
                    endPoint: direction == .topLeftToBottomRight ? .bottomTrailing : .bottomLeading,
                ))
        }
    }
}

extension ARGB {
    var color: Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: Double((value >> 24) & 0xFF) / 255,
        )
    }

    init(_ color: Color) {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .white
        func byte(_ component: CGFloat) -> UInt32 { UInt32((min(max(component, 0), 1) * 255).rounded()) }
        self.init(byte(nsColor.alphaComponent) << 24 | byte(nsColor.redComponent) << 16 | byte(nsColor.greenComponent) << 8
            | byte(nsColor.blueComponent))
    }
}

/// A slider with its value next to it
struct ValueSlider: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }), in: Double(range.lowerBound) ... Double(range.upperBound))
                .frame(minWidth: 160)
            Text("\(value) \(unit)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}
