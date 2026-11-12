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
        return CGSize(width: ideal.width, height: min(ideal.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

// MARK: - The strip

/// The menu bar item as it is now, half again as big, at the top of the panel. "Edit" turns it into its workspaces, to
/// be customized like a toolbar: drag a workspace from the grid into it, drag one within it to reorder, drag one out (or
/// ×) to remove it. The order is the order of the favorites (see ``StripWell``)
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
                    guard case .workspace(let name)? = items.first.flatMap(PanelDrag.init) else { return false }
                    viewModel.dropFavorite(name, before: nil)
                    return true
                } isTargeted: { isTargeted = $0 }
                Button(isEditing ? "Done" : "Edit") {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { isEditing.toggle() }
                }
                .controlSize(.small)
                .help(isEditing ? "" : "Choose the workspaces of the menu bar and their order")
            }
            if isEditing {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.favorites.isEmpty
                        ? "Every workspace with windows. Drag workspaces here to choose them and their order."
                        : "Drag to reorder. Drag out or × to remove. The workspace you're on comes after them.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if !state.favorites.isEmpty {
                        Button("Automatic") { viewModel.clearFavorites() }
                            .buttonStyle(.link)
                            .help("Every workspace with windows, as they come and go")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
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
                }
            }
            .contentShape(Self.shape)
            .draggable(PanelDrag.workspace(name).string) { DragChip(name: name) }
            .dropDestination(for: String.self) { items, _ in
                guard case .workspace(let dropped)? = items.first.flatMap(PanelDrag.init), dropped != name else { return false }
                viewModel.dropFavorite(dropped, before: name)
                return true
            } isTargeted: { isTargeted = $0 }
            .help(isFavorite ? "Drag to reorder, drag out to remove" : "Shown because you're on it")
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
            Image(cgImage, scale: 2, label: Text(state.trayText))
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
    /// Off while the strip is edited: the tiles themselves are dragged then
    let canDragWindows: Bool

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
                    .modifier(DraggableWindow(windowId: window.windowId, isEnabled: canDragWindows && !isLastOfMore, appBundleUrl: window.appBundleUrl))
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
    }
}
