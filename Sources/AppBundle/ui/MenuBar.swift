import Common
import Foundation
import SwiftUI

/// The panel of the menu bar item (see ``MenuBarItem``)
@MainActor
struct MenuBarPanel: View {
    static let width: CGFloat = 312

    /// What the screen has under the menu bar item (see ``MenuBarPanelFrame``)
    let maxHeight: CGFloat
    @EnvironmentObject var viewModel: TrayMenuModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @Namespace private var focusNamespace
    @State private var isStylePickerShown: Bool
    @State private var isEditingStrip: Bool
    @State private var isScrolled = false

    /// - Parameter isStylePickerShown: the panel opens with the styles (the tests measure it)
    /// - Parameter isEditingStrip: the panel opens with the strip being edited
    init(maxHeight: CGFloat, isStylePickerShown: Bool = false, isEditingStrip: Bool = false) {
        self.maxHeight = maxHeight
        _isStylePickerShown = State(initialValue: isStylePickerShown)
        _isEditingStrip = State(initialValue: isEditingStrip)
    }

    private static let spacing: CGFloat = 12
    private static let stylePickerId = "stylePicker"

    /// As high as its content, at most `maxHeight`: then the header stays, and what is under it scrolls
    var body: some View {
        HeightLimit(maxHeight: maxHeight) {
            VStack(spacing: 0) {
                header
                    .padding([.top, .horizontal], MenuBarPanelWindow.padding)
                    .padding(.bottom, Self.spacing)
                    .overlay(alignment: .bottom) { Divider().opacity(isScrolled ? 1 : 0) }
                ScrollViewReader { scrollView in
                    ScrollView(.vertical) {
                        content
                            .padding([.horizontal, .bottom], MenuBarPanelWindow.padding)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 0.5 } action: { _, isScrolled in
                        self.isScrolled = isScrolled
                    }
                    // The styles open at the bottom: under the edge of a panel that scrolls
                    .onChange(of: isStylePickerShown) {
                        if isStylePickerShown { scrollView.scrollTo(Self.stylePickerId, anchor: .top) }
                    }
                }
            }
        }
        .frame(width: Self.width)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            if viewModel.axPermissionStatus != .granted {
                permissionCallout
            } else {
                if viewModel.settingsHaveProblems {
                    configWarnings
                }
                if viewModel.isEnabled {
                    StripWellView(isEditing: $isEditingStrip)
                    // The strip is edited like a toolbar: what can be in it takes the place of the tiles
                    if isEditingStrip {
                        StripEditorView().transition(.opacity)
                    } else {
                        workspaces.transition(.opacity)
                    }
                }
            }
            Divider()
            actions
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: viewModel.isEnabled)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(aeroSpaceAppName).font(.headline)
                Button {
                    "\(aeroSpaceAppName) v\(aeroSpaceAppVersion) \(gitHash)".copyToClipboard()
                } label: {
                    HStack(spacing: 4) {
                        Text("v\(aeroSpaceAppVersion) · \(gitShortHash)")
                        Image(systemName: "doc.on.doc")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Copy the version")
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(get: { viewModel.isEnabled }, set: { _ in toggleEnabled() }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(viewModel.isEnabled ? "Disable \(aeroSpaceAppName)" : "Enable \(aeroSpaceAppName)")
        }
    }

    private var permissionCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(aeroSpaceAppName) needs the Accessibility permission to move windows", systemImage: "lock.shield")
                .font(.callout)
            Button("Grant Permission…") { viewModel.axPermissionStatus = .waitingWithPrompt }
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var configWarnings: some View {
        Button {
            SettingsWindowController.shared.show()
        } label: {
            Label("The settings need attention…", systemImage: "exclamationmark.triangle.fill")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.orange)
    }

    @ViewBuilder
    private var workspaces: some View {
        let workspaces = viewModel.workspaces.filter(\.isListed)
        VStack(alignment: .leading, spacing: 6) {
            Text("Workspaces")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TileGlassContainer {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(workspaces, id: \.name) { WorkspaceTile(workspace: $0, focusNamespace: focusNamespace) }
                }
            }
            // The focus slides to the workspace that a click (or a shortcut) focused
            .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: workspaces.first(where: \.isFocused)?.name)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { SettingsWindowController.shared.show() } label: { Label("Settings…", systemImage: "gearshape") }
                .help("Shortcuts, window rules, gaps, the focus border, …")
            Spacer()
            Button {
                Task.startUnstructured {
                    runTerminationHandlerOnce()
                    terminateApp()
                }
            } label: {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut("Q", modifiers: .command)
        }
        .controlSize(.small)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { isStylePickerShown.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "paintbrush")
                        Text("Menu bar style")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(isStylePickerShown ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(isStylePickerShown ? .primary : .secondary)
                .help("How the menu bar shows the workspaces (experimental: no stability guarantees)")
                .accessibilityValue(isStylePickerShown ? "expanded" : "collapsed")
                Spacer(minLength: 8)
                Link("Based on AeroSpace (MIT)", destination: URL(string: "https://github.com/nikitabobko/AeroSpace").orDie())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            .id(Self.stylePickerId)
            if isStylePickerShown {
                MenuBarStylePicker()
                    .transition(reduceMotion ? AnyTransition(OpacityTransition()) : AnyTransition(OpacityTransition().combined(with: MoveTransition(edge: .top))))
            }
        }
    }

    private func toggleEnabled() {
        Task.startUnstructured {
            try await runLightSession(.menuBarButton, .forceRun) {
                _ = await EnableCommand(args: EnableCmdArgs(rawArgs: [], targetState: .toggle)).run(.defaultEnv, .emptyStdin)
            }
        }
    }
}

@MainActor
private struct WorkspaceTile: View {
    let workspace: WorkspaceViewModel
    let focusNamespace: Namespace.ID
    @EnvironmentObject private var viewModel: TrayMenuModel
    @State private var isHovered = false
    @State private var isTargeted = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: MenuBarPanelWindow.innerCornerRadius, style: .continuous) }

    var body: some View {
        let isFavorite = viewModel.experimentalUISettings.favoriteWorkspaces.contains(workspace.name)
        Button {
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            let name = workspace.name
            Task.startUnstructured {
                try await runLightSession(.menuBarButton, token) { _ = Workspace.get(byName: name).focusWorkspace() }
            }
        } label: {
            VStack(spacing: 5) {
                Text(workspace.name)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(workspace.isEffectivelyEmpty && !workspace.isFocused ? .secondary : .primary)
                if workspace.windows.isEmpty {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(height: PaneMapView.size.height)
                } else {
                    PaneMapView(windows: workspace.windows)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background { shape.fill(background) }
            .overlay { shape.strokeBorder(Color.accentColor, lineWidth: 1.5).opacity(isTargeted ? 1 : 0) }
            .modifier(FocusHighlight(isFocused: workspace.isFocused, shape: shape, namespace: focusNamespace))
            .overlay(alignment: .bottomTrailing) {
                if isHovered || isFavorite {
                    FavoriteStar(name: workspace.name, isFavorite: isFavorite) { viewModel.toggleFavorite(workspace.name) }
                        .padding(3)
                }
            }
            .overlay(alignment: .topLeading) {
                if workspace.windowCount > 1 {
                    Text("\(workspace.windowCount)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 2) {
                    if workspace.monitorName != nil {
                        Image(systemName: "display")
                    }
                    if workspace.hasFullscreenWindows {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                }
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(5)
            }
            .contentShape(shape)
        }
        .buttonStyle(TileButtonStyle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(help)
        // The name and the number in the corner alone read "1, 2"
        .accessibilityLabel("Workspace \(workspace.name)")
        .accessibilityValue(accessibilityValue(isFavorite: isFavorite))
        .accessibilityAddTraits(workspace.isFocused ? .isSelected : [])
        .accessibilityAction(named: isFavorite ? "Remove from the Menu Bar" : "Keep in the Menu Bar") {
            viewModel.toggleFavorite(workspace.name) // The star is there only under the mouse
        }
        .contextMenu {
            Button(isFavorite ? "Remove from the Menu Bar" : "Keep in the Menu Bar", systemImage: isFavorite ? "star.slash" : "star") {
                viewModel.toggleFavorite(workspace.name)
            }
        }
        // A window dragged from another workspace moves here
        .dropDestination(for: String.self) { items, _ in
            guard case .window(let windowId)? = items.first.flatMap(PanelDrag.init),
                  !workspace.windows.contains(where: { $0.windowId == windowId })
            else { return false }
            moveWindowFromPanel(windowId, to: workspace.name)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var windowsText: String? {
        switch workspace.windowCount {
            case 0: nil
            case 1: "1 window"
            default: "\(workspace.windowCount) windows"
        }
    }

    private var help: String {
        var lines = [workspace.name + workspace.suffix]
        lines.append([windowsText, workspace.monitorName.map { "on \($0)" }].compactMap(\.self).joined(separator: " "))
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func accessibilityValue(isFavorite: Bool) -> String {
        [
            windowsText ?? "empty",
            workspace.monitorName.map { "on \($0)" },
            workspace.hasFullscreenWindows ? "fullscreen" : nil,
            isFavorite ? "kept in the menu bar" : nil,
        ].compactMap(\.self).joined(separator: ", ")
    }

    private var background: Color {
        switch true {
            case isHovered: Color.primary.opacity(0.10)
            case workspace.isVisible: Color.primary.opacity(0.08)
            default: Color.primary.opacity(0.04)
        }
    }
}

/// Gives way a little while it's pressed
private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// The styles of the menu bar item, each one as it would look now, and the details of the one under the mouse (the menu
/// bar shows it then), or of the chosen one. Only how the item looks: its workspaces and what a click on them does are
/// with the strip (``StripEditorView``)
@MainActor
private struct MenuBarStylePicker: View {
    @EnvironmentObject var viewModel: TrayMenuModel
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @State private var previews = MenuBarStylePreviews()

    var body: some View {
        let state = viewModel.menuBarState
        let selected = viewModel.experimentalUISettings.displayStyle // Not the one that is previewed
        let detailed = viewModel.previewStyle ?? selected
        let isDark = colorScheme == .dark
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                ForEach(MenuBarStyle.allCases) { style in
                    let image = previews.image(state.with(style: style), isDark: isDark)
                    MenuBarStyleCard(style: style, isSelected: style == selected, image: image) {
                        viewModel.setMenuBarStyle(style)
                    }
                }
            }
            MenuBarStyleDetails(style: detailed, image: previews.image(state.with(style: detailed), isDark: isDark))
        }
        // The mouse leaves the cards with the picker: the menu bar shows the chosen style again
        .onDisappear { viewModel.previewMenuBarStyle(nil) }
    }
}

/// The menu bar item in every style, for the cards. The picker is evaluated whenever the mouse goes to another card: a
/// style is drawn again only when what it shows changes
@MainActor
private final class MenuBarStylePreviews {
    private var drawn: [MenuBarStyle: (state: MenuBarState, isDark: Bool, image: CGImage?)] = [:]

    /// - Returns: the item at twice its size in points
    func image(_ state: MenuBarState, isDark: Bool) -> CGImage? {
        if let drawn = drawn[state.style], drawn.state == state, drawn.isDark == isDark { return drawn.image }
        let image = MenuBarItemContent(state: state, transition: nil, color: isDark ? .white : .black).cgImage
        drawn[state.style] = (state, isDark, image)
        return image
    }
}

extension CGImage {
    /// Of a menu bar item (see ``MenuBarStylePreviews``): its width in the menu bar
    fileprivate var menuBarItemWidth: Int { width / 2 }
}

/// A style: the menu bar item as it would look now, scaled down if it's wider than the card, and its name. The rest is
/// told once, under the cards (``MenuBarStyleDetails``)
@MainActor
private struct MenuBarStyleCard: View {
    let style: MenuBarStyle
    let isSelected: Bool
    let image: CGImage?
    let select: () -> Void
    @EnvironmentObject private var viewModel: TrayMenuModel
    @State private var isHovered = false

    private static let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
    private static let maxPreviewWidth: CGFloat = 120

    var body: some View {
        Button(action: select) {
            VStack(spacing: 3) {
                Group {
                    if let image {
                        let size = CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
                        let scale = min(1, Self.maxPreviewWidth / max(size.width, 1))
                        Image(image, scale: 2, label: Text(style.title))
                            .resizable()
                            .frame(width: size.width * scale, height: size.height * scale)
                    }
                }
                .frame(height: MenuBarItemContent.height / 2)
                HStack(spacing: 3) {
                    if isSelected { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                    Text(style.title).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(6)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(isHovered ? 0.10 : 0.05),
                in: Self.shape,
            )
            .overlay { Self.shape.strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5) }
            .contentShape(Self.shape)
        }
        .buttonStyle(TileButtonStyle())
        .onHover { hovering in
            isHovered = hovering
            // The menu bar shows the style while the mouse is over it. The next card may come first: only its own
            if hovering {
                viewModel.previewMenuBarStyle(style)
            } else if viewModel.previewStyle == style {
                viewModel.previewMenuBarStyle(nil)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        // What the details under the cards show for the style under the mouse: VoiceOver has no mouse
        .accessibilityLabel(style.title)
        .accessibilityValue(["shows \(style.encodingsText)", image.map { "\($0.menuBarItemWidth) points wide" }].compactMap(\.self).joined(separator: ", "))
        .accessibilityHint(Text(style.explanation))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// What a style shows of the workspaces, how wide it is in the menu bar now, and what it is: for one style, not on
/// every card. As high as two lines for the last, also when it takes one: the window of the panel doesn't change its
/// height under the mouse
@MainActor
private struct MenuBarStyleDetails: View {
    let style: MenuBarStyle
    let image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(style.title).fontWeight(.semibold).foregroundStyle(.primary)
                Text("shows \(style.encodingsText)")
                Spacer(minLength: 4)
                if let image {
                    Text("\(image.menuBarItemWidth) pt").monospacedDigit().help("Its width in the menu bar now")
                }
            }
            .lineLimit(1)
            // Two lines of text, whatever the text: the room that `lineLimit` reserves is a point less than they take
            Text(" \n ")
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
                .overlay(alignment: .topLeading) { Text(style.explanation).lineLimit(2) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true) // The cards tell it
    }
}

extension MenuBarState {
    /// The state in another style, for a preview: without the warning about the settings, which every style shows
    fileprivate func with(style: MenuBarStyle) -> MenuBarState {
        var result = self
        result.style = style
        result.settingsHaveProblems = false
        return result
    }
}

/// The icons of the apps in the workspace tiles and in the menu bar item. The body of the tiles is evaluated on every
/// update of the tray model, the icon lookup (file system, IconServices) runs once per app. The system icon is lazy and
/// multi resolution: only the representation for the size that it's drawn at is ever rendered
@MainActor
enum AppIconCache {
    static let size: CGFloat = 14
    private static var icons: [URL: NSImage] = [:]
    private static var bitmaps: [URL: CGImage] = [:]

    static func icon(_ url: URL) -> NSImage {
        if let icon = icons[url] { return icon }
        if icons.count >= 64 { icons.removeAll() } // Apps that were used once. Rebuilding is cheap
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: size, height: size)
        icons[url] = icon
        return icon
    }

    /// The icon for the menu bar item, `side` pixels wide, in the standard dynamic range: the renderer of the item drew
    /// it all in an HDR color space for an HDR icon (macOS 26), in which its transparent parts came out black. Drawn once
    /// per app, the frames of an animation only copy it
    static func bitmap(_ url: URL, side: Int) -> CGImage? {
        if let bitmap = bitmaps[url], bitmap.width == side { return bitmap }
        if bitmaps.count >= 64 { bitmaps.removeAll() }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = unsafe CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        icon(url).draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let bitmap = context.makeImage()
        bitmaps[url] = bitmap
        return bitmap
    }
}

@MainActor
func openSettingsButton() -> some View {
    Button("Open Settings") { SettingsWindowController.shared.show() }
}

func shortcutGroup(label: some View, content: some View) -> some View {
    GroupBox {
        VStack(alignment: .trailing, spacing: 6) {
            label
                .foregroundStyle(Color.secondary)
            content
        }
    }
}
