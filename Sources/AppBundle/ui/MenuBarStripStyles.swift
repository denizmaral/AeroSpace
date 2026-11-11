import AppKit
import SwiftUI

// The strip styles that tell what the workspaces hold: how many windows (Skyline, Panes), which apps (Shelf). Drawn at
// twice their size in points, like the other styles (see MenuBarItemContent). Every workspace of the strip has a slot
// of at least 10 points: a click there focuses it (see MenuBarClicks)

// MARK: - Skyline

/// A bar for each workspace, as high as it has windows: the tallest one is crowded, a stub is free. The focused one is a
/// tile with its name, a workspace shown on another monitor stands on a line. The bars grow and shrink when windows come
/// and go
struct WorkspaceSkyline: View {
    let state: MenuBarState
    let from: MenuBarState?
    let progress: Double
    let color: Color

    private static let gap: CGFloat = 8
    private static let baseline: CGFloat = 36
    private static let fontSize: CGFloat = 20

    private struct Look {
        var width: CGFloat = 0
        var height: CGFloat = 0
        var opacity: CGFloat = 0
        var radius: CGFloat = 4
        var base: CGFloat = 0
        var name: CGFloat = 0

        func mixed(with other: Look, _ t: CGFloat) -> Look {
            Look(
                width: lerp(width, other.width, t),
                height: lerp(height, other.height, t),
                opacity: lerp(opacity, other.opacity, t),
                radius: lerp(radius, other.radius, t),
                base: lerp(base, other.base, t),
                name: lerp(name, other.name, t),
            )
        }
    }

    private static func look(_ workspace: WorkspaceViewModel?) -> Look {
        guard let workspace else { return Look() }
        if workspace.isFocused {
            return Look(width: max(28, textWidth(workspace.name, size: fontSize, weight: .bold) + 12), height: 32, opacity: 1, radius: 8, name: 1)
        }
        let height: CGFloat = switch min(workspace.windowCount, 4) {
            case 0: 4
            case 1: 10
            case 2: 18
            case 3: 26
            default: 32
        }
        let opacity: CGFloat = workspace.windowCount == 0 ? 0.3 : workspace.isVisible ? 1 : 0.6
        return Look(width: 12, height: height, opacity: opacity, radius: min(4, height / 2), base: workspace.isVisible ? 1 : 0)
    }

    /// Each bar and the gap after it (see ``MenuBarItemContent/workspaceSlots(_:_:)``)
    static func slots(_ strip: [WorkspaceViewModel]) -> [WorkspaceSlot] {
        var x: CGFloat = 0
        return strip.map { workspace in
            let width = look(workspace).width + gap
            defer { x += width }
            return WorkspaceSlot(name: workspace.name, minX: x, maxX: x + width)
        }
    }

    var body: some View {
        let entries = stripEntries(from: (from ?? state).strip, to: state.strip)
        let t = CGFloat(progress)
        var x: CGFloat = 0
        var bars: [(name: String, rect: CGRect, look: Look)] = []
        for entry in entries {
            let look = Self.look(entry.from).mixed(with: Self.look(entry.to), t)
            let presence = lerp(entry.from == nil ? 0 : 1, entry.to == nil ? 0 : 1, t)
            if look.width > 0 {
                bars.append((entry.name, CGRect(x: x + Self.gap * presence / 2, y: Self.baseline - look.height, width: look.width, height: look.height), look))
            }
            x += look.width + Self.gap * presence
        }
        return Canvas { context, _ in
            for bar in bars {
                if bar.look.base > 0 {
                    var base = context
                    base.opacity = bar.look.base
                    base.fill(Path(roundedRect: CGRect(x: bar.rect.midX - 8, y: Self.baseline + 1.5, width: 16, height: 2), cornerRadius: 1), with: .color(color))
                }
                context.drawLayer { layer in
                    layer.opacity = bar.look.opacity
                    layer.fill(Path(roundedRect: bar.rect, cornerRadius: bar.look.radius, style: .continuous), with: .color(color))
                    if bar.look.name > 0 { // Cut out of the tile
                        layer.blendMode = .destinationOut
                        layer.opacity = bar.look.name
                        layer.draw(Text(bar.name).font(.system(size: Self.fontSize, weight: .bold, design: .rounded)).foregroundStyle(.black), at: CGPoint(x: bar.rect.midX, y: bar.rect.midY), anchor: .center)
                    }
                }
            }
        }
        .frame(width: max(x, 1), height: MenuBarItemContent.height)
    }
}

// MARK: - Panes

/// Every workspace is a tiny screen, split into its windows: one, two or three side by side, four and more in a grid. The
/// screens of the workspaces that the monitors show stand on a foot, the focused one has its name before it. A new
/// window splits the last pane, a closed one gives its room back
struct WorkspacePanes: View {
    let state: MenuBarState
    let from: MenuBarState?
    let progress: Double
    let color: Color

    private static let screen = CGSize(width: 22, height: 18)
    private static let screenY: CGFloat = 8
    private static let gap: CGFloat = 5
    private static let paneGap: CGFloat = 2
    private static let letterGap: CGFloat = 5
    private static let fontSize: CGFloat = 22

    private struct Look {
        var letterWidth: CGFloat = 0
        var name: CGFloat = 0
        var panes: CGFloat = 0
        var outline: CGFloat = 0
        var stand: CGFloat = 0
        var presence: CGFloat = 0

        var width: CGFloat { (letterWidth + WorkspacePanes.screen.width) * presence }

        func mixed(with other: Look, _ t: CGFloat) -> Look {
            Look(
                letterWidth: lerp(letterWidth, other.letterWidth, t),
                name: lerp(name, other.name, t),
                panes: lerp(panes, other.panes, t),
                outline: lerp(outline, other.outline, t),
                stand: lerp(stand, other.stand, t),
                presence: lerp(presence, other.presence, t),
            )
        }
    }

    private static func look(_ workspace: WorkspaceViewModel?) -> Look {
        guard let workspace else { return Look() }
        return Look(
            letterWidth: workspace.isFocused ? textWidth(workspace.name, size: fontSize, weight: .bold) + letterGap : 0,
            name: workspace.isFocused ? 1 : 0,
            panes: workspace.isVisible ? 1 : 0.6,
            outline: workspace.windowCount == 0 ? (workspace.isVisible ? 0.9 : 0.35) : 0,
            stand: workspace.isVisible ? 1 : 0,
            presence: 1,
        )
    }

    /// The panes of a screen with `count` windows, from its top left corner
    static func panes(_ count: Int) -> [CGRect] {
        let (w, h, g) = (screen.width, screen.height, paneGap)
        switch min(count, 4) {
            case 0: return []
            case 4:
                let (pw, ph) = ((w - g) / 2, (h - g) / 2)
                return [
                    CGRect(x: 0, y: 0, width: pw, height: ph), CGRect(x: pw + g, y: 0, width: pw, height: ph),
                    CGRect(x: 0, y: ph + g, width: pw, height: ph), CGRect(x: pw + g, y: ph + g, width: pw, height: ph),
                ]
            case let n:
                let pw = (w - g * CGFloat(n - 1)) / CGFloat(n)
                return (0 ..< n).map { CGRect(x: CGFloat($0) * (pw + g), y: 0, width: pw, height: h) }
        }
    }

    /// Each screen and the gap after it (see ``MenuBarItemContent/workspaceSlots(_:_:)``)
    static func slots(_ strip: [WorkspaceViewModel]) -> [WorkspaceSlot] {
        var x: CGFloat = 0
        return strip.map { workspace in
            let width = look(workspace).width + gap
            defer { x += width }
            return WorkspaceSlot(name: workspace.name, minX: x, maxX: x + width)
        }
    }

    private struct Cell {
        let name: String
        let x: CGFloat
        let look: Look
        /// The panes before and after the change: a split moves (up to three panes), a grid comes in (four and more)
        let panes: [(rect: CGRect, opacity: CGFloat)]
    }

    var body: some View {
        let entries = stripEntries(from: (from ?? state).strip, to: state.strip)
        let t = CGFloat(progress)
        var x: CGFloat = 0
        var cells: [Cell] = []
        for entry in entries {
            let look = Self.look(entry.from).mixed(with: Self.look(entry.to), t)
            let fromCount = entry.from?.windowCount ?? entry.to?.windowCount ?? 0
            let toCount = entry.to?.windowCount ?? fromCount
            cells.append(Cell(name: entry.name, x: x + Self.gap * look.presence / 2, look: look, panes: Self.movingPanes(fromCount, toCount, t)))
            x += look.width + Self.gap * look.presence
        }
        return Canvas { context, _ in
            for cell in cells where cell.look.presence > 0 {
                var cellContext = context
                cellContext.opacity = cell.look.presence
                let screenX = cell.x + cell.look.letterWidth
                if cell.look.name > 0 {
                    var letter = cellContext
                    letter.opacity = cell.look.name * cell.look.presence
                    letter.draw(
                        Text(cell.name).font(.system(size: Self.fontSize, weight: .bold, design: .rounded)).foregroundStyle(color),
                        at: CGPoint(x: cell.x + (cell.look.letterWidth - Self.letterGap) / 2, y: Self.screenY + Self.screen.height / 2),
                        anchor: .center,
                    )
                }
                let screenRect = CGRect(x: screenX, y: Self.screenY, width: Self.screen.width, height: Self.screen.height)
                let screenShape = Path(roundedRect: screenRect, cornerRadius: 4, style: .continuous)
                if cell.look.outline > 0 {
                    var outline = cellContext
                    outline.opacity = cell.look.outline * cell.look.presence
                    outline.stroke(Path(roundedRect: screenRect.insetBy(dx: 1, dy: 1), cornerRadius: 3.5, style: .continuous), with: .color(color), lineWidth: 2)
                }
                cellContext.drawLayer { layer in
                    layer.clip(to: screenShape)
                    for pane in cell.panes where pane.opacity > 0 {
                        var paneLayer = layer
                        paneLayer.opacity = pane.opacity * cell.look.panes
                        paneLayer.fill(Path(roundedRect: pane.rect.offsetBy(dx: screenX, dy: Self.screenY), cornerRadius: 1.5), with: .color(color))
                    }
                }
                if cell.look.stand > 0 {
                    var stand = cellContext
                    stand.opacity = cell.look.stand * cell.look.presence
                    stand.fill(Path(roundedRect: CGRect(x: screenRect.midX - 5, y: screenRect.maxY + 3, width: 10, height: 3), cornerRadius: 1.5), with: .color(color))
                }
            }
        }
        .frame(width: max(x, 1), height: MenuBarItemContent.height)
    }

    /// A split moves: the new pane grows out of the right edge, a closed one shrinks into it. Into or out of the grid of
    /// four, the panes fade
    private static func movingPanes(_ fromCount: Int, _ toCount: Int, _ t: CGFloat) -> [(rect: CGRect, opacity: CGFloat)] {
        let (from, to) = (min(fromCount, 4), min(toCount, 4))
        if from == to { return panes(to).map { ($0, 1) } }
        if from == 4 || to == 4 {
            return panes(from).map { ($0, 1 - t) } + panes(to).map { ($0, t) }
        }
        let fromPanes = panes(from), toPanes = panes(to)
        let edge = CGRect(x: screen.width, y: 0, width: 0, height: screen.height)
        return (0 ..< max(from, to)).map { index in
            (lerp(index < from ? fromPanes[index] : edge, index < to ? toPanes[index] : edge, t), 1)
        }
    }
}

// MARK: - Shelf

/// Every workspace is the icon of its first app: what is where, without names to remember. The focused one is a tile
/// with its name and the icons of its apps, an empty one a dot, one shown on another monitor stands on a line
struct WorkspaceShelf: View {
    let state: MenuBarState
    let from: MenuBarState?
    let progress: Double
    let color: Color

    /// Smaller with more than six workspaces in the strip: the menu bar has room for a few items only
    private struct Metrics {
        let icon: CGFloat
        let gap: CGFloat
        let focusedIcons: Int

        init(_ strip: [WorkspaceViewModel]) {
            (icon, gap, focusedIcons) = strip.count > 6 ? (22, 3, 1) : (26, 4, 3)
        }
    }

    private static let tile: CGFloat = 32
    private static let focusedIcon: CGFloat = 28
    private static let dot: CGFloat = 6
    private static let fontSize: CGFloat = 21

    private static func width(_ workspace: WorkspaceViewModel?, _ metrics: Metrics) -> CGFloat {
        guard let workspace else { return 0 }
        if workspace.isFocused {
            let icons = CGFloat(min(workspace.appBundleUrls.count, metrics.focusedIcons))
            return max(tile, textWidth(workspace.name, size: fontSize, weight: .bold) + 14) + icons * (focusedIcon + 3)
        }
        return workspace.windowCount == 0 ? 14 : metrics.icon
    }

    /// Each workspace and the gap after it (see ``MenuBarItemContent/workspaceSlots(_:_:)``)
    static func slots(_ strip: [WorkspaceViewModel]) -> [WorkspaceSlot] {
        let metrics = Metrics(strip)
        var x: CGFloat = 0
        return strip.map { workspace in
            let width = width(workspace, metrics) + metrics.gap
            defer { x += width }
            return WorkspaceSlot(name: workspace.name, minX: x, maxX: x + width)
        }
    }

    private struct Cell {
        let x: CGFloat
        let from: (workspace: WorkspaceViewModel, opacity: CGFloat)?
        let to: (workspace: WorkspaceViewModel, opacity: CGFloat)?
    }

    var body: some View {
        let toStrip = state.strip
        let entries = stripEntries(from: (from ?? state).strip, to: toStrip)
        let fromMetrics = Metrics((from ?? state).strip), toMetrics = Metrics(toStrip)
        let t = CGFloat(progress)
        var x: CGFloat = 0
        var cells: [Cell] = []
        var icons: [URL: Image] = [:]
        for entry in entries {
            let changes = entry.from?.isFocused != entry.to?.isFocused || entry.from?.windowCount == 0 && entry.to?.windowCount != 0
            let width = lerp(Self.width(entry.from, fromMetrics), Self.width(entry.to, toMetrics), t)
            let gap = lerp(entry.from == nil ? 0 : fromMetrics.gap, entry.to == nil ? 0 : toMetrics.gap, t)
            cells.append(Cell(
                x: x + gap / 2,
                from: changes || entry.to == nil ? entry.from.map { ($0, 1 - t) } : nil,
                to: entry.to.map { ($0, changes || entry.from == nil ? t : 1) },
            ))
            for workspace in [entry.from, entry.to].compactMap(\.self) {
                let side = Int(workspace.isFocused ? Self.focusedIcon : toMetrics.icon)
                for url in workspace.appBundleUrls.prefix(workspace.isFocused ? toMetrics.focusedIcons : 1) where icons[url] == nil {
                    icons[url] = AppIconCache.bitmap(url, side: side).map { Image(decorative: $0, scale: 1) }
                }
            }
            x += width + gap
        }
        let metrics = toMetrics
        return Canvas { context, _ in
            for cell in cells {
                for side in [cell.from, cell.to].compactMap(\.self) where side.opacity > 0 {
                    var cellContext = context
                    cellContext.opacity = side.opacity
                    Self.draw(side.workspace, at: cell.x, metrics, icons, color, &cellContext)
                }
            }
        }
        .frame(width: max(x, 1), height: MenuBarItemContent.height)
    }

    private static func draw(_ workspace: WorkspaceViewModel, at x: CGFloat, _ metrics: Metrics, _ icons: [URL: Image], _ color: Color, _ context: inout GraphicsContext) {
        let midY = MenuBarItemContent.height / 2
        if workspace.isFocused {
            let tileWidth = max(tile, textWidth(workspace.name, size: fontSize, weight: .bold) + 14)
            let tileRect = CGRect(x: x, y: midY - tile / 2, width: tileWidth, height: tile)
            context.drawLayer { layer in
                layer.fill(Path(roundedRect: tileRect, cornerRadius: 9, style: .continuous), with: .color(color))
                layer.blendMode = .destinationOut
                layer.draw(Text(workspace.name).font(.system(size: fontSize, weight: .bold, design: .rounded)).foregroundStyle(.black), at: CGPoint(x: tileRect.midX, y: tileRect.midY), anchor: .center)
            }
            for (index, url) in workspace.appBundleUrls.prefix(metrics.focusedIcons).enumerated() {
                guard let icon = icons[url] else { continue }
                context.draw(icon, in: CGRect(x: tileRect.maxX + 3 + CGFloat(index) * (focusedIcon + 3), y: midY - focusedIcon / 2, width: focusedIcon, height: focusedIcon))
            }
        } else if workspace.windowCount == 0 {
            var dotContext = context
            dotContext.opacity *= workspace.isVisible ? 0.9 : 0.35
            dotContext.fill(Path(ellipseIn: CGRect(x: x + (14 - dot) / 2, y: midY - dot / 2, width: dot, height: dot)), with: .color(color))
        } else {
            let rect = CGRect(x: x, y: midY - metrics.icon / 2 - (workspace.isVisible ? 2 : 0), width: metrics.icon, height: metrics.icon)
            var iconContext = context
            iconContext.opacity *= workspace.isVisible ? 1 : 0.75
            if let icon = workspace.appBundleUrls.first.flatMap({ icons[$0] }) {
                iconContext.draw(icon, in: rect)
            } else { // An app without an icon: its workspace's name
                iconContext.stroke(Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 6, style: .continuous), with: .color(color), lineWidth: 2)
                iconContext.draw(Text(workspace.name).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(color), at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            }
            if workspace.isVisible { // Shown on another monitor
                context.fill(Path(roundedRect: CGRect(x: rect.midX - 6, y: rect.maxY + 2, width: 12, height: 3), cornerRadius: 1.5), with: .color(color))
            }
        }
    }
}
