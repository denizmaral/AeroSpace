import AppKit
import Common
import Foundation
import SwiftUI

/// The menu bar item. SwiftUI puts only an image or a text into the menu bar (AeroSpace issue #1122): the item is drawn
/// into an image, once per change, and once per frame while a change is animated (``MenuBarAnimator``)
@MainActor
struct MenuBarLabel: View {
    @Environment(\.colorScheme) private var menuColorScheme: ColorScheme
    @EnvironmentObject private var viewModel: TrayMenuModel
    @ObservedObject private var animator = MenuBarAnimator.shared

    var body: some View {
        let state = viewModel.menuBarState
        MenuBarItemImage(
            content: MenuBarItemContent(state: state, transition: animator.transition, color: menuColorScheme == .dark ? .white : .black),
            label: state.trayText,
        )
    }
}

/// The menu bar item as an image, as in the menu bar
@MainActor
struct MenuBarItemImage: View {
    let content: MenuBarItemContent
    let label: String

    var body: some View {
        switch content.cgImage {
            // Using scale: 1 results in a blurry image for unknown reasons
            case let cgImage?: Image(cgImage, scale: 2, label: Text(label))
            // In case image can't be rendered fallback to plain text
            case nil: Text(label)
        }
    }
}

/// The menu bar item, drawn at twice its size in points (the image has a scale of 2)
@MainActor
struct MenuBarItemContent: View {
    let state: MenuBarState
    let transition: MenuBarTransition?
    let color: Color

    static let height: CGFloat = 40

    /// The item drawn at the size of its pixels
    var cgImage: CGImage? { ImageRenderer(content: self).cgImage }

    var body: some View {
        HStack(spacing: 6) {
            if state.settingsHaveProblems {
                Image(systemName: "exclamationmark.triangle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(color)
                    .frame(width: Self.height, height: Self.height)
            }
            if let transition {
                if !transition.reduceMotion, transition.from.style == state.style, state.style.movesOnChange {
                    style(state, from: transition.from, progress: transition.progress)
                } else { // Fades
                    ZStack {
                        style(transition.from, from: nil, progress: 1).opacity(1 - transition.progress)
                        style(state, from: nil, progress: 1).opacity(transition.progress)
                    }
                }
            } else {
                style(state, from: nil, progress: 1)
            }
        }
    }

    @ViewBuilder
    private func style(_ state: MenuBarState, from: MenuBarState?, progress: Double) -> some View {
        switch state.style {
            case .monospacedText: PushedText(text: state.trayText, from: from?.trayText, progress: progress.easedOut, design: .monospaced, color: color)
            case .systemText: PushedText(text: state.trayText, from: from?.trayText, progress: progress.easedOut, design: .default, color: color)
            case .squares, .i3, .i3Ordered: ClassicMenuBarItem(state: state, color: color)
            case .pills: withMode(state) { WorkspacePills(state: state, from: from, progress: progress.easedInOut, color: color) }
            case .dots: withMode(state) { WorkspaceDots(state: state, from: from, progress: progress.easedInOut, color: color) }
            case .workspaceApps: withMode(state) { WorkspaceWithApps(state: state, from: from, progress: progress.easedOut, color: color) }
        }
    }

    /// The binding mode (other than the main one) in a circle, before the workspaces
    private func withMode(_ state: MenuBarState, @ViewBuilder _ workspaces: () -> some View) -> some View {
        HStack(spacing: 6) {
            if let mode = state.mode {
                if let symbol = mode.systemImageName {
                    Image(systemName: symbol)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .fontWeight(.semibold)
                        .foregroundStyle(color)
                        .frame(width: 30, height: 30)
                } else {
                    Text("(\(mode.name))").font(.system(.largeTitle)).foregroundStyle(color)
                }
            }
            workspaces()
        }
    }
}

extension MenuBarStyle {
    /// The styles that move from the old state to the new one. The others fade
    fileprivate var movesOnChange: Bool {
        switch self {
            case .monospacedText, .systemText, .pills, .dots, .workspaceApps: true
            case .squares, .i3, .i3Ordered: false
        }
    }
}

// MARK: - Text

/// The new text pushes the old one up
private struct PushedText: View {
    let text: String
    let from: String?
    let progress: Double
    let design: Font.Design
    let color: Color

    var body: some View {
        let font = Font.system(.largeTitle, design: design)
        ZStack {
            if let from, from != text {
                Text(from).font(font).offset(y: -pushDistance * progress).opacity(1 - progress)
                Text(text).font(font).offset(y: pushDistance * (1 - progress)).opacity(progress)
            } else {
                Text(text).font(font)
            }
        }
        .foregroundStyle(color)
        .clipped()
    }

    /// Less than the height of the text: the old text is still partly there while it fades
    private let pushDistance: CGFloat = 20
}

// MARK: - Pills

/// All listed workspaces in a row, the focused one filled. The fill slides from the old workspace to the new one, and
/// the letters that it passes are cut out of it
private struct WorkspacePills: View {
    let state: MenuBarState
    let from: MenuBarState?
    let progress: Double
    let color: Color

    private static let pillHeight: CGFloat = 30
    private static let gap: CGFloat = 3
    private static let cornerRadius: CGFloat = 9
    private static let fontSize: CGFloat = 21
    private static let font = Font.system(size: fontSize, weight: .semibold, design: .rounded)
    private static let outlineWidth: CGFloat = 2.5

    private struct Cell {
        let name: String
        let rect: CGRect
        let letterOpacity: CGFloat
        let outlineOpacity: CGFloat
    }

    var body: some View {
        let entries = stripEntries(from: from?.workspaces ?? state.workspaces, to: state.workspaces)
        let t = CGFloat(progress)
        let midY = MenuBarItemContent.height / 2
        var x: CGFloat = 0
        var cells: [Cell] = []
        var fromFocused: CGRect? = nil
        var toFocused: CGRect? = nil
        for entry in entries {
            let width = max(Self.pillHeight - 6, textWidth(entry.name, size: Self.fontSize, weight: .semibold) + 12)
            // A workspace that comes or goes grows or shrinks from its middle
            let presence = lerp(entry.from == nil ? 0 : 1, entry.to == nil ? 0 : 1, t)
            let midX = x + (width + Self.gap) * presence / 2
            let rect = CGRect(x: midX - width * presence / 2, y: midY - Self.pillHeight / 2, width: width * presence, height: Self.pillHeight)
            let fullRect = CGRect(x: midX - width / 2, y: rect.minY, width: width, height: Self.pillHeight)
            if entry.from?.isFocused == true { fromFocused = fullRect }
            if entry.to?.isFocused == true { toFocused = fullRect }
            cells.append(Cell(
                name: entry.name,
                rect: rect,
                letterOpacity: lerp(entry.from.map(Self.letterOpacity) ?? 0, entry.to.map(Self.letterOpacity) ?? 0, t),
                outlineOpacity: lerp(entry.from.map(Self.outlineOpacity) ?? 0, entry.to.map(Self.outlineOpacity) ?? 0, t),
            ))
            x += (width + Self.gap) * presence
        }
        let highlight: (rect: CGRect, opacity: CGFloat)? = switch (fromFocused, toFocused) {
            case let (from?, to?): (lerp(from, to, t), 1)
            case let (nil, to?): (to, t)
            case let (from?, nil): (from, 1 - t)
            case (nil, nil): nil
        }
        return Canvas { context, _ in
            let font = Self.font
            let highlightPath = highlight.map { Path(roundedRect: $0.rect, cornerRadius: Self.cornerRadius, style: .continuous) }
            context.drawLayer { layer in
                // The letters under the fill are cut out of it, they aren't drawn on it
                if let highlight, let highlightPath, highlight.opacity == 1 { layer.clip(to: highlightPath, options: .inverse) }
                for cell in cells {
                    if cell.outlineOpacity > 0 {
                        var outline = layer
                        outline.opacity = cell.outlineOpacity
                        outline.stroke(
                            Path(roundedRect: cell.rect.insetBy(dx: Self.outlineWidth / 2, dy: Self.outlineWidth / 2), cornerRadius: Self.cornerRadius - 1, style: .continuous),
                            with: .color(color),
                            lineWidth: Self.outlineWidth,
                        )
                    }
                    var letter = layer
                    letter.opacity = cell.letterOpacity
                    letter.draw(Text(cell.name).font(font).foregroundStyle(color), at: CGPoint(x: cell.rect.midX, y: cell.rect.midY), anchor: .center)
                }
            }
            if let highlight, let highlightPath {
                context.drawLayer { layer in
                    layer.opacity = highlight.opacity
                    layer.fill(highlightPath, with: .color(color))
                    layer.blendMode = .destinationOut
                    for cell in cells where cell.rect.intersects(highlight.rect) {
                        var letter = layer
                        letter.opacity = cell.letterOpacity
                        letter.draw(Text(cell.name).font(font).foregroundStyle(.black), at: CGPoint(x: cell.rect.midX, y: cell.rect.midY), anchor: .center)
                    }
                }
            }
        }
        .frame(width: max(x, 1), height: MenuBarItemContent.height)
    }

    private static func letterOpacity(_ workspace: WorkspaceViewModel) -> CGFloat {
        workspace.isEffectivelyEmpty && !workspace.isFocused ? 0.45 : 1
    }

    /// Shown on another monitor
    private static func outlineOpacity(_ workspace: WorkspaceViewModel) -> CGFloat {
        workspace.isVisible && !workspace.isFocused ? 0.9 : 0
    }
}

// MARK: - Dots

/// A dot per listed workspace: the focused one is stretched to a capsule with its name. When the focus moves, the old
/// capsule shrinks back to a dot while the new dot grows
private struct WorkspaceDots: View {
    let state: MenuBarState
    let from: MenuBarState?
    let progress: Double
    let color: Color

    private static let gap: CGFloat = 7
    private static let fontSize: CGFloat = 20
    private static let font = Font.system(size: fontSize, weight: .bold, design: .rounded)

    /// How a workspace looks
    private struct Look {
        var width: CGFloat = 0
        var height: CGFloat = 0
        var fill: CGFloat = 0
        var ring: CGFloat = 0
        var name: CGFloat = 0

        func mixed(with other: Look, _ t: CGFloat) -> Look {
            Look(
                width: lerp(width, other.width, t),
                height: lerp(height, other.height, t),
                fill: lerp(fill, other.fill, t),
                ring: lerp(ring, other.ring, t),
                name: lerp(name, other.name, t),
            )
        }
    }

    private static func look(_ workspace: WorkspaceViewModel?) -> Look {
        guard let workspace else { return Look() }
        return switch true {
            case workspace.isFocused:
                Look(width: max(28, textWidth(workspace.name, size: fontSize, weight: .bold) + 16), height: 28, fill: 1, name: 1)
            case workspace.isVisible && workspace.isEffectivelyEmpty: Look(width: 13, height: 13, ring: 1) // On another monitor
            case workspace.isVisible: Look(width: 13, height: 13, fill: 1) // On another monitor
            case workspace.isEffectivelyEmpty: Look(width: 10, height: 10, ring: 0.6)
            default: Look(width: 10, height: 10, fill: 0.55)
        }
    }

    var body: some View {
        let entries = stripEntries(from: from?.workspaces ?? state.workspaces, to: state.workspaces)
        let t = CGFloat(progress)
        let midY = MenuBarItemContent.height / 2
        var x: CGFloat = 0
        var dots: [(name: String, rect: CGRect, look: Look)] = []
        for entry in entries {
            let look = Self.look(entry.from).mixed(with: Self.look(entry.to), t)
            let presence = lerp(entry.from == nil ? 0 : 1, entry.to == nil ? 0 : 1, t)
            if look.width > 0 {
                dots.append((entry.name, CGRect(x: x + Self.gap * presence / 2, y: midY - look.height / 2, width: look.width, height: look.height), look))
            }
            x += look.width + Self.gap * presence
        }
        return Canvas { context, _ in
            for dot in dots {
                let capsule = Path(roundedRect: dot.rect, cornerRadius: dot.rect.height / 2, style: .continuous)
                if dot.look.ring > 0 {
                    var ring = context
                    ring.opacity = dot.look.ring
                    ring.stroke(Path(roundedRect: dot.rect.insetBy(dx: 1.25, dy: 1.25), cornerRadius: dot.rect.height / 2, style: .continuous), with: .color(color), lineWidth: 2.5)
                }
                if dot.look.fill > 0 {
                    context.drawLayer { layer in
                        layer.opacity = dot.look.fill
                        layer.fill(capsule, with: .color(color))
                        if dot.look.name > 0 { // Cut out of the capsule
                            layer.blendMode = .destinationOut
                            layer.opacity = dot.look.name
                            layer.draw(Text(dot.name).font(Self.font).foregroundStyle(.black), at: CGPoint(x: dot.rect.midX, y: dot.rect.midY), anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: max(x, 1), height: MenuBarItemContent.height)
    }
}

// MARK: - Workspace with its apps

/// The name of the focused workspace on a tile, and the icons of its apps. The new name pushes the old one up, and the
/// new icons come in one after the other
private struct WorkspaceWithApps: View {
    let state: MenuBarState
    let from: MenuBarState?
    let progress: Double
    let color: Color

    private static let tileHeight: CGFloat = 32
    /// The old name is still partly on the tile while it fades
    private static let pushDistance: CGFloat = 22
    private static let cornerRadius: CGFloat = 9
    private static let fontSize: CGFloat = 22
    private static let font = Font.system(size: fontSize, weight: .bold, design: .rounded)
    private static let iconSize: CGFloat = 30
    private static let iconGap: CGFloat = 3
    private static let tileGap: CGFloat = 6
    private static let maxIcons = 3

    var body: some View {
        let t = CGFloat(progress)
        let newWorkspace = state.focusedWorkspace
        let oldWorkspace = from.map { $0.focusedWorkspace } ?? newWorkspace
        let newName = newWorkspace?.name ?? ""
        let oldName = oldWorkspace?.name ?? ""
        let newIcons = Self.icons(newWorkspace)
        let oldIcons = Self.icons(oldWorkspace)
        let iconsChange = newWorkspace?.appBundleUrls.prefix(Self.maxIcons) != oldWorkspace?.appBundleUrls.prefix(Self.maxIcons)
        let tileWidth = lerp(Self.tileWidth(oldName), Self.tileWidth(newName), t)
        let iconsWidth = lerp(Self.iconsWidth(oldIcons.count), Self.iconsWidth(newIcons.count), iconsChange ? t : 1)
        let midY = MenuBarItemContent.height / 2
        let tile = CGRect(x: 0, y: midY - Self.tileHeight / 2, width: tileWidth, height: Self.tileHeight)
        return Canvas { context, _ in
            context.drawLayer { layer in
                let path = Path(roundedRect: tile, cornerRadius: Self.cornerRadius, style: .continuous)
                layer.fill(path, with: .color(color))
                layer.clip(to: path)
                layer.blendMode = .destinationOut
                let center = CGPoint(x: tile.midX, y: tile.midY)
                if oldName != newName {
                    var old = layer
                    old.opacity = 1 - t
                    old.draw(Text(oldName).font(Self.font).foregroundStyle(.black), at: CGPoint(x: center.x, y: center.y - Self.pushDistance * t), anchor: .center)
                    layer.opacity = t
                    layer.draw(Text(newName).font(Self.font).foregroundStyle(.black), at: CGPoint(x: center.x, y: center.y + Self.pushDistance * (1 - t)), anchor: .center)
                } else {
                    layer.draw(Text(newName).font(Self.font).foregroundStyle(.black), at: center, anchor: .center)
                }
            }
            let iconsX = tile.maxX + Self.tileGap
            if iconsChange {
                for (index, icon) in oldIcons.enumerated() {
                    var old = context
                    old.opacity = 1 - t
                    old.draw(icon, in: Self.iconRect(index, x: iconsX, midY: midY).offsetBy(dx: 0, dy: -8 * t))
                }
                for (index, icon) in newIcons.enumerated() {
                    // One after the other
                    let local = min(1, max(0, (t - 0.12 * CGFloat(index)) / 0.7))
                    var new = context
                    new.opacity = local
                    new.draw(icon, in: Self.iconRect(index, x: iconsX, midY: midY).offsetBy(dx: 0, dy: 10 * (1 - local)))
                }
            } else {
                for (index, icon) in newIcons.enumerated() {
                    context.draw(icon, in: Self.iconRect(index, x: iconsX, midY: midY))
                }
            }
        }
        .frame(width: tileWidth + (iconsWidth > 0 ? Self.tileGap + iconsWidth : 0), height: MenuBarItemContent.height)
    }

    private static func icons(_ workspace: WorkspaceViewModel?) -> [Image] {
        (workspace?.appBundleUrls.prefix(maxIcons) ?? []).compactMap {
            AppIconCache.bitmap($0, side: Int(iconSize)).map { Image(decorative: $0, scale: 1) }
        }
    }

    private static func tileWidth(_ name: String) -> CGFloat {
        max(tileHeight, textWidth(name, size: fontSize, weight: .bold) + 16)
    }

    private static func iconsWidth(_ count: Int) -> CGFloat {
        count == 0 ? 0 : CGFloat(count) * iconSize + CGFloat(count - 1) * iconGap
    }

    private static func iconRect(_ index: Int, x: CGFloat, midY: CGFloat) -> CGRect {
        CGRect(x: x + CGFloat(index) * (iconSize + iconGap), y: midY - iconSize / 2, width: iconSize, height: iconSize)
    }
}

// MARK: - Squares, i3

/// The styles of AeroSpace
private struct ClassicMenuBarItem: View {
    let state: MenuBarState
    let color: Color

    private let itemSize = CGFloat(40)
    private let itemBorderSize = CGFloat(3)
    private let itemCornerRadius = CGFloat(6)

    var body: some View {
        HStack(spacing: 6) {
            switch state.style {
                case .i3:
                    squares
                    let workspaces = state.workspaces.filter { !$0.isEffectivelyEmpty && !$0.isVisible }
                    if !workspaces.isEmpty {
                        otherWorkspaces(with: workspaces)
                    }
                case .i3Ordered:
                    if let modeItem = state.mode {
                        itemView(for: modeItem)
                        modeSeparator(with: .monospaced)
                    }
                    let orderedWorkspaces = state.workspaces.filter { !$0.isEffectivelyEmpty || $0.isVisible }
                    ForEach(orderedWorkspaces, id: \.name) { item in
                        let trayItem = TrayItem(
                            type: .workspace,
                            name: item.name,
                            isActive: item.isFocused,
                            hasFullscreenWindows: item.hasFullscreenWindows,
                        )
                        itemView(for: trayItem)
                            .opacity(item.isVisible ? 1 : 0.5)
                    }
                default: squares
            }
        }
    }

    private var squares: some View {
        ForEach(state.trayItems, id: \.id) { item in
            itemView(for: item)
            if item.type == .mode {
                modeSeparator(with: .monospaced)
            }
        }
    }

    private func otherWorkspaces(with otherWorkspaces: [WorkspaceViewModel]) -> some View {
        Group {
            Text("|")
                .font(.system(.largeTitle))
                .foregroundStyle(color)
                .bold()
                .padding(.bottom, 6)
            ForEach(otherWorkspaces, id: \.name) { item in
                itemView(for: TrayItem(type: .workspace, name: item.name, isActive: false, hasFullscreenWindows: item.hasFullscreenWindows))
            }
        }
        .opacity(0.6)
    }

    private func modeSeparator(with design: Font.Design) -> some View {
        Text(":")
            .font(.system(.largeTitle, design: design))
            .foregroundStyle(color)
            .bold()
    }

    @ViewBuilder
    private func itemView(for item: TrayItem) -> some View {
        let view = itemSubView(for: item)
        if item.hasFullscreenWindows {
            let strokeStyle = StrokeStyle(lineWidth: 2, lineCap: .square, lineJoin: .miter, miterLimit: 10, dash: [10, 5], dashPhase: 3)
            view
                .padding(4)
                .overlay {
                    RoundedRectangle(cornerRadius: itemCornerRadius, style: .continuous)
                        .strokeBorder(color, style: strokeStyle)
                }
        } else {
            view
        }
    }

    @ViewBuilder
    private func itemSubView(for item: TrayItem) -> some View {
        // If workspace name contains emojis we use the plain emoji in text to avoid visibility issues scaling the emoji to fit the squares
        if item.name.containsEmoji() {
            Text(item.name)
                .font(.system(.largeTitle))
                .foregroundStyle(color)
                .frame(height: itemSize)
        } else {
            if let imageName = item.systemImageName {
                Image(systemName: imageName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(color)
                    .frame(width: itemSize, height: itemSize)
            } else {
                let text = Text(item.name)
                    .font(.system(.largeTitle))
                    .bold()
                    .padding(.horizontal, itemBorderSize * 2)
                    .frame(height: itemSize)
                if item.isActive {
                    ZStack {
                        text.background {
                            RoundedRectangle(cornerRadius: itemCornerRadius, style: .circular)
                        }
                        text.blendMode(.destinationOut)
                    }
                    .compositingGroup()
                    .foregroundStyle(color)
                    .frame(height: itemSize)
                } else {
                    text.background {
                        RoundedRectangle(cornerRadius: itemCornerRadius, style: .continuous)
                            .strokeBorder(lineWidth: itemBorderSize)
                    }
                    .foregroundStyle(color)
                    .frame(height: itemSize)
                }
            }
        }
    }
}

// MARK: - Helpers

/// A workspace in a strip of the menu bar item (pills, dots) during a change: how it's listed before and after it. nil:
/// not listed
struct StripEntry {
    let name: String
    let from: WorkspaceViewModel?
    let to: WorkspaceViewModel?
}

/// The workspaces listed before or after the change, in the order of the workspaces. A workspace that is gone (an
/// empty workspace that was left) stays where it was, until it has shrunk away
func stripEntries(from: [WorkspaceViewModel], to: [WorkspaceViewModel]) -> [StripEntry] {
    let fromListed = from.filter(\.isListed)
    let toListed = to.filter(\.isListed)
    let fromByName = Dictionary(fromListed.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    let toNames = Set(toListed.map(\.name))
    var result: [StripEntry] = []
    var fromIndex = 0
    func appendGone(until end: Int) {
        while fromIndex < end {
            let workspace = fromListed[fromIndex]
            if !toNames.contains(workspace.name) { result.append(StripEntry(name: workspace.name, from: workspace, to: nil)) }
            fromIndex += 1
        }
    }
    for workspace in toListed {
        if fromByName[workspace.name] != nil, let index = fromListed[fromIndex...].firstIndex(where: { $0.name == workspace.name }) {
            appendGone(until: index)
            fromIndex = index + 1
        }
        result.append(StripEntry(name: workspace.name, from: fromByName[workspace.name], to: workspace))
    }
    appendGone(until: fromListed.count)
    return result
}

/// The width of a name in the rounded system font, to lay out the strips before they are drawn
@MainActor
private func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
    let key = TextWidthKey(text: text, size: size, weight: weight.rawValue)
    if let width = textWidths[key] { return width }
    let system = NSFont.systemFont(ofSize: size, weight: weight)
    let font = system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? system
    let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
    if textWidths.count >= 256 { textWidths.removeAll() }
    textWidths[key] = width
    return width
}

// periphery:ignore - the properties are only hashed
private struct TextWidthKey: Hashable {
    let text: String
    let size: CGFloat
    let weight: CGFloat
}

@MainActor private var textWidths: [TextWidthKey: CGFloat] = [:]

private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
    CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t), width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
}

extension Double {
    fileprivate var easedOut: Double { 1 - pow(1 - self, 3) }
    fileprivate var easedInOut: Double { self < 0.5 ? 4 * self * self * self : 1 - pow(-2 * self + 2, 3) / 2 }
}

extension String {
    fileprivate func containsEmoji() -> Bool {
        unicodeScalars.contains { $0.properties.isEmoji && $0.properties.isEmojiPresentation }
    }
}
