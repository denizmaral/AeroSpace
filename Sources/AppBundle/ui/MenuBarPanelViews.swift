import AppKit
import Common
import SwiftUI

// MARK: - The height of the panel

/// Its content as high as it wants to be, but not higher than `maxHeight`: what the content does with less is up to it
/// (the panel scrolls). In one pass: the window of the panel follows this size (see ``MenuBarItem``), and a height that
/// is measured first and applied after would open the panel at the wrong height for a moment
struct HeightLimit: SwiftUI.Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        // Whole points: the window may round half a point away (a display of one pixel per point), and a panel that is
        // half a point too low for its content scrolls by it
        return CGSize(width: ideal.width, height: min(ideal.height.rounded(.up), maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

// MARK: - The strip

/// The menu bar item as it is now, half again as big, at the top of the panel. "Edit" turns it into its workspaces, to
/// be customized like a toolbar: drag a workspace from the palette under it (``StripEditorView``) into it, drag one
/// within it to reorder, drag one out (or ×) to remove it. The order is the order of the favorites (see ``StripWell``)
@MainActor
struct StripWellView: View {
    @Binding var isEditing: Bool
    @EnvironmentObject private var viewModel: TrayMenuModel
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @State private var isTargeted = false

    var body: some View {
        let state = viewModel.menuBarState
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Group {
                    if isEditing {
                        chips(state)
                    } else {
                        LiveMenuBarItem(state: state, isDark: colorScheme == .dark)
                            .equatable()
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 38)
                .padding(.horizontal, 6)
                .background(Color.primary.opacity(isTargeted ? 0.14 : 0.06), in: Self.shape)
                .overlay { Self.shape.strokeBorder(Color.accentColor.opacity(isTargeted ? 0.8 : 0), lineWidth: 1.5) }
                .dropDestination(for: String.self) { items, _ in
                    guard isEditing, let name = items.first.flatMap(PanelDrag.init)?.droppedWorkspace else { return false }
                    viewModel.dropFavorite(name, before: nil)
                    return true
                } isTargeted: { isTargeted = $0 && isEditing }
                editButton
            }
            if isEditing {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.favorites.isEmpty
                        ? "Automatic: every workspace with windows. Click or drag workspaces to choose your own, also empty ones."
                        : "Drag to reorder, drag out or × to remove. The workspace you're on comes after them.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if !state.favorites.isEmpty {
                        Button("Automatic") { viewModel.clearFavorites() }
                            .buttonStyle(.link)
                            .foregroundStyle(.tint) // Not the gray of the text next to it: it's a button
                            .help("Every workspace with windows, as they come and go")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var editButton: some View {
        let button = Button(isEditing ? "Done" : "Edit") {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { isEditing.toggle() }
        }
        .controlSize(.small)
        if isEditing {
            button
        } else {
            button.help("Choose the workspaces of the menu bar, their order, and what a click on them does")
        }
    }

    /// The workspaces of the strip: the favorites can be moved and removed, the one that is shown only because it's
    /// focused can be dragged in place
    private func chips(_ state: MenuBarState) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 28, maximum: 40), spacing: 4)], spacing: 4) {
            ForEach(state.strip, id: \.name) { workspace in
                WellChip(name: workspace.name, isFavorite: state.favorites.contains(workspace.name) || state.favorites.isEmpty)
            }
        }
        .padding(.vertical, 6)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: state.strip.map(\.name))
    }

    static let shape = RoundedRectangle(cornerRadius: MenuBarPanelWindow.innerCornerRadius, style: .continuous)
}

/// A workspace in the strip while it's edited
@MainActor
private struct WellChip: View {
    let name: String
    /// In the strip because it was chosen (or, without favorites, because it has windows)
    let isFavorite: Bool
    @EnvironmentObject private var viewModel: TrayMenuModel
    @State private var isTargeted = false

    private static let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)

    var body: some View {
        Text(name)
            .font(.system(.callout, design: .rounded).weight(.semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 26)
            .foregroundStyle(isFavorite ? .primary : .secondary)
            .background(Color.primary.opacity(isFavorite ? 0.14 : 0.05), in: Self.shape)
            .accessibilityLabel(isFavorite ? "Workspace \(name)" : "Workspace \(name), shown because you're on it")
            .overlay(alignment: .leading) { // Where a dropped workspace goes: before this one
                Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 3).offset(x: -3.5).opacity(isTargeted ? 1 : 0)
            }
            .overlay(alignment: .topTrailing) {
                if isFavorite {
                    Button { viewModel.removeFavorite(name) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10)).symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                    .help("Remove \(name) from the menu bar")
                    .accessibilityLabel("Remove \(name) from the menu bar")
                }
            }
            .contentShape(Self.shape)
            .draggable(PanelDrag.stripWorkspace(name).string) { DragChip(name: name) }
            .dropDestination(for: String.self) { items, _ in
                guard let dropped = items.first.flatMap(PanelDrag.init)?.droppedWorkspace, dropped != name else { return false }
                viewModel.dropFavorite(dropped, before: name)
                return true
            } isTargeted: { isTargeted = $0 }
            .help(isFavorite ? "Drag to reorder, drag out to remove" : "Shown because you're on it")
    }
}

/// Under the strip while it's edited, in place of the tiles: every workspace to choose from, like the palette of a
/// toolbar that is customized (also the empty ones, which have no tile), and how the strip behaves. Everything about the
/// strip is here, and nothing of it with the styles
@MainActor
struct StripEditorView: View {
    @EnvironmentObject private var viewModel: TrayMenuModel

    var body: some View {
        let state = viewModel.menuBarState
        let style = viewModel.experimentalUISettings.displayStyle // The chosen one, not one that is previewed
        VStack(alignment: .leading, spacing: 10) {
            if !style.showsStrip {
                // Nothing in the menu bar changes with what is chosen here: said, not dimmed
                Label("“\(style.title)” shows no row of workspaces. This is for the styles that do, like Pills or Dots.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("All workspaces")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 27, maximum: 44), spacing: 5)], spacing: 5) {
                    ForEach(state.workspaces, id: \.name) { workspace in
                        PaletteChip(
                            name: workspace.name,
                            isFavorite: state.favorites.contains(workspace.name),
                            isShown: state.isInStrip(workspace),
                            hasWindows: !workspace.isEffectivelyEmpty,
                        ) { viewModel.toggleFavorite(workspace.name) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                option(
                    "Click to switch workspace",
                    hint: "A right click opens this panel",
                    isOn: $viewModel.experimentalUISettings.switchesWorkspaceOnClick,
                )
                option(
                    "Group by monitor",
                    hint: "With more than one monitor",
                    isOn: Binding(
                        get: { viewModel.experimentalUISettings.groupsWorkspacesByMonitor },
                        set: { viewModel.setGroupsWorkspacesByMonitor($0) },
                    ),
                )
            }
        }
        // A workspace dragged out of the strip: it isn't in the menu bar any more
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard case .stripWorkspace(let name)? = items.first.flatMap(PanelDrag.init) else { return false }
            viewModel.removeFavorite(name)
            return true
        }
    }

    /// The title and its hint, and the switch at the edge. The switch carries both for VoiceOver: a switch with a title
    /// that is shown is a text and a switch without a name there
    private func option(_ title: String, hint: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityHidden(true)
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityHint(Text(hint))
        }
    }
}

/// A workspace in the palette under the strip: a click keeps it in the menu bar (or not any more), a drag puts it at a
/// place in the strip. A tap and not a button, which keeps the mouse to itself: the chip is dragged too
@MainActor
private struct PaletteChip: View {
    let name: String
    let isFavorite: Bool
    /// In the menu bar right now: chosen, or (without favorites) a workspace with windows
    let isShown: Bool
    let hasWindows: Bool
    let toggle: () -> Void

    private static let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)

    var body: some View {
        Text(name)
            .font(.system(.callout, design: .rounded).weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 24)
            .foregroundStyle(isFavorite ? Color.white : hasWindows ? .primary : .secondary)
            .background(isFavorite ? Color.accentColor : Color.primary.opacity(isShown ? 0.14 : 0.05), in: Self.shape)
            .contentShape(Self.shape)
            .onTapGesture(perform: toggle)
            .draggable(PanelDrag.workspace(name).string) { DragChip(name: name) }
            .animation(.snappy(duration: 0.2), value: isFavorite)
            .help(isFavorite ? "In the menu bar, also when it's empty. Click to remove" : "Click to keep \(name) in the menu bar, or drag it to its place")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Workspace \(name)")
            .accessibilityValue(isFavorite ? "kept in the menu bar" : isShown ? "in the menu bar now" : "not in the menu bar")
            .accessibilityAddTraits(isFavorite ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, toggle)
    }
}

/// What the mouse carries while a workspace is dragged
struct DragChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(.callout, design: .rounded).weight(.semibold))
            .frame(width: 30, height: 26)
            .background(Color.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .foregroundStyle(.white)
    }
}

/// The menu bar item as it is now, half again as big. Drawn again only when what it shows changes (not for the frames of
/// an animation: the panel isn't drawn for every frame)
@MainActor
private struct LiveMenuBarItem: View, Equatable {
    let state: MenuBarState
    let isDark: Bool

    private static let scale: CGFloat = 1.5
    private static let maxWidth: CGFloat = 220

    var body: some View {
        if let cgImage = MenuBarItemContent(state: state, transition: nil, color: isDark ? .white : .black).cgImage {
            let size = CGSize(width: CGFloat(cgImage.width) / 2 * Self.scale, height: CGFloat(cgImage.height) / 2 * Self.scale)
            let fit = min(1, Self.maxWidth / max(size.width, 1))
            Image(cgImage, scale: 2, label: Text("The menu bar item: \(state.trayText)"))
                .resizable()
                .frame(width: size.width * fit, height: size.height * fit)
        }
    }
}

// MARK: - The windows of a tile

/// The windows of a workspace as panes of a small screen, each one with the icon of its app. In the panel, a window is
/// dragged by its icon to another workspace
@MainActor
struct PaneMapView: View {
    let windows: [WindowSummary]

    static let size = CGSize(width: 40, height: 24)
    private static let gap: CGFloat = 2

    var body: some View {
        let (panes, hidden) = PaneMap.panes(count: windows.count, in: Self.size, gap: Self.gap)
        ZStack(alignment: .topLeading) {
            ForEach(Array(zip(panes.indices, panes)), id: \.0) { index, pane in
                let window = windows[index]
                let isLastOfMore = hidden > 0 && index == panes.count - 1
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.primary.opacity(0.10))
                    .overlay {
                        if isLastOfMore {
                            Text("+\(hidden + 1)")
                                .font(.system(size: 8, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        } else if let url = window.appBundleUrl {
                            let side = max(6, min(pane.width, pane.height) - 3)
                            Image(nsImage: AppIconCache.icon(url))
                                .resizable()
                                .frame(width: min(side, 14), height: min(side, 14))
                        }
                    }
                    .frame(width: pane.width, height: pane.height)
                    .offset(x: pane.minX, y: pane.minY)
                    .modifier(DraggableWindow(windowId: window.windowId, isEnabled: !isLastOfMore, appBundleUrl: window.appBundleUrl))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }
}

private struct DraggableWindow: ViewModifier {
    let windowId: OpaqueWindowId
    let isEnabled: Bool
    let appBundleUrl: URL?

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.draggable(PanelDrag.window(windowId).string) {
                Group {
                    if let appBundleUrl {
                        Image(nsImage: AppIconCache.icon(appBundleUrl)).resizable().frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "macwindow").font(.system(size: 20))
                    }
                }
            }
        } else {
            content
        }
    }
}

/// Moves a window that was dragged onto a workspace in the panel. Nothing happens for a window that was closed
/// meanwhile, or that is on that workspace already
@MainActor
func moveWindowFromPanel(_ windowId: OpaqueWindowId, to workspace: String) {
    guard let token: RunSessionGuard = .isServerEnabled else { return }
    Task.startUnstructured {
        try await runLightSession(.menuBarButton, token) {
            guard let window = Window.get(byId: windowId), window.nodeWorkspace?.name != workspace,
                  case .cmd(let command) = parseCommand(["move-node-to-workspace", "--window-id", windowId.description, workspace])
            else { return }
            _ = await command.run(.defaultEnv, .emptyStdin)
        }
    }
}

// MARK: - The focus and the favorites of a tile

/// The focused workspace: tinted glass that flows to the next focused tile (macOS 26), or the blue outline that slides
/// to it
struct FocusHighlight: ViewModifier {
    let isFocused: Bool
    let shape: RoundedRectangle
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if isFocused {
                content
                    .glassEffect(.regular.tint(Color.accentColor.opacity(0.45)).interactive(), in: shape)
                    .glassEffectID("focus", in: namespace)
            } else {
                content
            }
        } else {
            content.background {
                if isFocused {
                    shape
                        .fill(Color.accentColor.opacity(0.22))
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                        .matchedGeometryEffect(id: "focus", in: namespace)
                }
            }
        }
    }
}

/// The tiles share their glass (macOS 26): the focus flows from one to the next
struct TileGlassContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 8) { content }
        } else {
            content
        }
    }
}

/// Keeps the workspace in the menu bar, or not any more. Shown while the mouse is over the tile, and on a favorite
struct FavoriteStar: View {
    let name: String
    let isFavorite: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isFavorite ? Color.yellow : .secondary)
                .frame(width: 13, height: 13)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isFavorite ? "Remove \(name) from the menu bar" : "Keep \(name) in the menu bar")
        .accessibilityLabel(isFavorite ? "Remove \(name) from the menu bar" : "Keep \(name) in the menu bar")
    }
}
