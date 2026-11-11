import Common
import Foundation
import SwiftUI

@MainActor
public func menuBar(viewModel: TrayMenuModel) -> some Scene {
    MenuBarExtra {
        // The window style panel is built only while it's open. The menu bar label is the only always-live view
        MenuBarPanel().environmentObject(viewModel)
    } label: {
        switch (viewModel.axPermissionStatus, viewModel.isEnabled) {
            case (.granted, true):
                MenuBarLabel().environmentObject(viewModel)
            case (.granted, false):
                Image(systemName: "pause.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case (_, _):
                Image(systemName: "exclamationmark.triangle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
        }
    }
    .menuBarExtraStyle(.window)
}

@MainActor
private struct MenuBarPanel: View {
    @EnvironmentObject var viewModel: TrayMenuModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @Namespace private var focusNamespace
    @State private var isStylePickerShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if viewModel.axPermissionStatus != .granted {
                permissionCallout
            } else {
                if viewModel.settingsHaveProblems {
                    configWarnings
                }
                if viewModel.isEnabled {
                    workspaces
                }
            }
            Divider()
            actions
            footer
        }
        .padding(14)
        .frame(width: 312)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: viewModel.isEnabled)
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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(workspaces, id: \.name) { WorkspaceTile(workspace: $0, focusNamespace: focusNamespace) }
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
                Spacer(minLength: 8)
                Link("Based on AeroSpace (MIT)", destination: URL(string: "https://github.com/nikitabobko/AeroSpace").orDie())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
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

    private static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        Button {
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            let name = workspace.name
            Task.startUnstructured {
                try await runLightSession(.menuBarButton, token) { _ = Workspace.get(byName: name).focusWorkspace() }
            }
        } label: {
            VStack(spacing: 4) {
                Text(workspace.name)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(workspace.isEffectivelyEmpty && !workspace.isFocused ? .secondary : .primary)
                HStack(spacing: 2) {
                    if workspace.appBundleUrls.isEmpty {
                        Image(systemName: "circle.dashed")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(workspace.appBundleUrls, id: \.self) { url in
                        Image(nsImage: AppIconCache.icon(url))
                            .resizable()
                            .frame(width: AppIconCache.size, height: AppIconCache.size)
                    }
                }
                .frame(height: 14)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .background {
                ZStack {
                    Self.shape.fill(background)
                    if workspace.isFocused {
                        Self.shape
                            .fill(Color.accentColor.opacity(0.22))
                            .strokeBorder(Color.accentColor, lineWidth: 1.5)
                            .matchedGeometryEffect(id: "focus", in: focusNamespace)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if workspace.windowCount > 1 {
                    Text("\(workspace.windowCount)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary)
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
            .contentShape(Self.shape)
        }
        .buttonStyle(TileButtonStyle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(help)
        .contextMenu {
            let isFavorite = viewModel.experimentalUISettings.favoriteWorkspaces.contains(workspace.name)
            Button(isFavorite ? "Remove from the Menu Bar" : "Keep in the Menu Bar", systemImage: isFavorite ? "pin.slash" : "pin") {
                viewModel.toggleFavorite(workspace.name)
            }
        }
    }

    private var help: String {
        var lines = [workspace.name + workspace.suffix]
        let windows = workspace.windowCount == 1 ? "1 window" : "\(workspace.windowCount) windows"
        lines.append([workspace.windowCount > 0 ? windows : nil, workspace.monitorName.map { "on \($0)" }].compactMap(\.self).joined(separator: " "))
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
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

/// The styles of the menu bar item, each one as it would look now
@MainActor
private struct MenuBarStylePicker: View {
    @EnvironmentObject var viewModel: TrayMenuModel
    @Environment(\.colorScheme) private var colorScheme: ColorScheme

    var body: some View {
        let state = viewModel.menuBarState
        let selected = state.style
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                ForEach(MenuBarStyle.allCases) { style in
                    let preview = MenuBarStylePreview(state: state.with(style: style), isDark: colorScheme == .dark)
                    MenuBarStyleCard(style: style, isSelected: style == selected, preview: preview) {
                        viewModel.setMenuBarStyle(style)
                    }
                }
            }
            FavoriteWorkspacesPicker(state: state)
        }
    }
}

/// The workspaces that the strips of the menu bar item show (see ``ExperimentalUISettings/favoriteWorkspaces``)
@MainActor
private struct FavoriteWorkspacesPicker: View {
    let state: MenuBarState
    @EnvironmentObject var viewModel: TrayMenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Workspaces in the menu bar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !state.favorites.isEmpty {
                    Button("Show all with windows") { viewModel.clearFavorites() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 27, maximum: 44), spacing: 5)], spacing: 5) {
                ForEach(state.workspaces, id: \.name) { workspace in
                    FavoriteWorkspaceChip(
                        name: workspace.name,
                        isFavorite: state.favorites.contains(workspace.name),
                        isShown: state.isInStrip(workspace),
                    ) { viewModel.toggleFavorite(workspace.name) }
                }
            }
            Text(state.favorites.isEmpty
                ? "Every workspace with windows. Pick the ones to keep there, also when they're empty."
                : "The picked ones, and the workspace that you're on.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(state.style.showsStrip ? 1 : 0.5)
        .help(state.style.showsStrip ? "" : "For the styles that show a row of workspaces: Pills, Dots, i3")
    }
}

@MainActor
private struct FavoriteWorkspaceChip: View {
    let name: String
    let isFavorite: Bool
    /// In the menu bar right now: picked, or (without favorites) a workspace with windows
    let isShown: Bool
    let toggle: () -> Void

    private static let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)

    var body: some View {
        Button(action: toggle) {
            Text(name)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 24)
                .foregroundStyle(isFavorite ? Color.white : isShown ? .primary : .secondary)
                .background(isFavorite ? Color.accentColor : Color.primary.opacity(isShown ? 0.12 : 0.05), in: Self.shape)
                .contentShape(Self.shape)
        }
        .buttonStyle(TileButtonStyle())
        .animation(.snappy(duration: 0.2), value: isFavorite)
        .help(isFavorite ? "Picked: always in the menu bar. Click to remove" : "Click to keep \(name) in the menu bar")
        .accessibilityAddTraits(isFavorite ? .isSelected : [])
    }
}

@MainActor
private struct MenuBarStyleCard: View {
    let style: MenuBarStyle
    let isSelected: Bool
    let preview: MenuBarStylePreview
    let select: () -> Void
    @State private var isHovered = false

    private static let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)

    var body: some View {
        Button(action: select) {
            VStack(spacing: 5) {
                preview
                    .equatable()
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                HStack(spacing: 3) {
                    if isSelected { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                    Text(style.title).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .padding(6)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(isHovered ? 0.08 : 0.03),
                in: Self.shape,
            )
            .overlay { Self.shape.strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5) }
            .contentShape(Self.shape)
        }
        .buttonStyle(TileButtonStyle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help(style.explanation)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The menu bar item in a style, scaled down if it's wider than the card. Drawn again only when what it shows changes
@MainActor
private struct MenuBarStylePreview: View, Equatable {
    let state: MenuBarState
    let isDark: Bool

    private static let maxWidth: CGFloat = 120

    var body: some View {
        if let cgImage = MenuBarItemContent(state: state, transition: nil, color: isDark ? .white : .black).cgImage {
            let size = CGSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2)
            let scale = min(1, Self.maxWidth / max(size.width, 1))
            Image(cgImage, scale: 2, label: Text(state.style.title))
                .resizable()
                .frame(width: size.width * scale, height: size.height * scale)
        }
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
