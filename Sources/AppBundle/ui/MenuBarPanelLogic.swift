import AppKit
import Common

/// The strip of the menu bar item, customized in the panel like a toolbar: workspaces are dragged into it, out of it and
/// within it (see `MenuBarPanel`). The order of the strip is the order of the favorites
enum StripWell {
    /// - Parameter strip: the favorites, or the workspaces that the strip shows without favorites: they become the
    ///   favorites, the dragged workspace joins them
    /// - Parameter other: the workspace that it's dropped before. nil: at the end
    static func favorites(dropping workspace: String, before other: String?, in strip: [String]) -> [String] {
        var result = strip.filter { $0 != workspace }
        result.insert(workspace, at: other.flatMap { result.firstIndex(of: $0) } ?? result.endIndex)
        return result
    }

    /// Dragged out of the strip. The last one gone: the strip shows every workspace with windows again
    static func favorites(removing workspace: String, from strip: [String]) -> [String] {
        strip.filter { $0 != workspace }
    }
}

/// What is dragged in the panel: a workspace (into the strip, within it, out of it) or a window (to another workspace).
/// A string: a type of its own would have to be declared in the Info.plist
enum PanelDrag: Equatable {
    case workspace(String)
    case window(OpaqueWindowId)

    private static let workspacePrefix = "marspace-workspace:"
    private static let windowPrefix = "marspace-window:"

    var string: String {
        switch self {
            case .workspace(let name): Self.workspacePrefix + name
            case .window(let id): Self.windowPrefix + id.description
        }
    }

    init?(_ string: String) {
        if string.hasPrefix(Self.workspacePrefix) {
            self = .workspace(String(string.dropFirst(Self.workspacePrefix.count)))
        } else if string.hasPrefix(Self.windowPrefix), let id = UInt64(string.dropFirst(Self.windowPrefix.count)) {
            self = .window(OpaqueWindowId(id))
        } else {
            return nil
        }
    }
}

/// The keyboard in the open panel: a workspace's key focuses it, with Option the workspace is kept in the menu bar (or
/// not any more). The key is matched without the modifiers: Option types another character (Option-G is © on a Swiss
/// German keyboard)
enum PanelKeyAction: Equatable {
    case focus(String)
    case toggleFavorite(String)

    /// - Parameter workspaces: the names of the workspaces
    /// - Returns: nil for a key that isn't a workspace, and with ⌘ or ⌃ (shortcuts like ⌘Q)
    static func of(charactersIgnoringModifiers characters: String?, modifiers: NSEvent.ModifierFlags, workspaces: [String]) -> PanelKeyAction? {
        let modifiers = modifiers.intersection([.command, .control, .option])
        guard let key = characters?.uppercased(), !key.isEmpty, modifiers.isDisjoint(with: [.command, .control]),
              let workspace = workspaces.first(where: { $0.uppercased() == key })
        else { return nil }
        return modifiers.contains(.option) ? .toggleFavorite(workspace) : .focus(workspace)
    }

    static func of(_ event: NSEvent, workspaces: [String]) -> PanelKeyAction? {
        guard event.type == .keyDown else { return nil }
        return of(charactersIgnoringModifiers: event.charactersIgnoringModifiers, modifiers: event.modifierFlags, workspaces: workspaces)
    }
}

/// The windows of a workspace as panes of a small screen, in the tiles of the panel: one, two or three side by side, four
/// and more in a grid of four (the fourth pane counts the others)
enum PaneMap {
    /// - Returns: the panes from the top left corner of the screen, and how many windows the last pane stands for more
    static func panes(count: Int, in size: CGSize, gap: CGFloat) -> (rects: [CGRect], hidden: Int) {
        switch count {
            case ...0: return ([], 0)
            case 1 ... 3:
                let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
                return ((0 ..< count).map { CGRect(x: CGFloat($0) * (width + gap), y: 0, width: width, height: size.height) }, 0)
            default:
                let (width, height) = ((size.width - gap) / 2, (size.height - gap) / 2)
                let rects = [
                    CGRect(x: 0, y: 0, width: width, height: height), CGRect(x: width + gap, y: 0, width: width, height: height),
                    CGRect(x: 0, y: height + gap, width: width, height: height), CGRect(x: width + gap, y: height + gap, width: width, height: height),
                ]
                return (rects, count - 4)
        }
    }
}

/// What a style of the menu bar item tells about the workspaces, for the chips of the style cards in the panel
enum MenuBarStyleEncoding: CaseIterable, Hashable {
    case names
    case windowCount
    case apps
    case monitors

    var symbol: String {
        switch self {
            case .names: "textformat"
            case .windowCount: "rectangle.split.2x1"
            case .apps: "app.dashed"
            case .monitors: "display.2"
        }
    }

    var help: String {
        switch self {
            case .names: "The names of the workspaces"
            case .windowCount: "How many windows a workspace has"
            case .apps: "The apps of the workspaces"
            case .monitors: "What every monitor shows"
        }
    }
}

extension MenuBarStyle {
    var encodings: [MenuBarStyleEncoding] {
        switch self {
            case .monospacedText, .systemText, .pills, .dots, .squares, .i3, .i3Ordered: [.names, .monitors]
            case .panes, .skyline: [.names, .windowCount, .monitors]
            case .shelf: [.names, .apps, .monitors]
            case .workspaceApps: [.names, .apps]
        }
    }
}
