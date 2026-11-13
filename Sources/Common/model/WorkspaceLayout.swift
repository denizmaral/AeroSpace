/// How a workspace arranges its windows, switched with `workspace-layout` (Omarchy cycles its workspaces through these)
public enum WorkspaceLayout: String, CaseIterable, Equatable, Sendable, AeroAny {
    /// The tiling tree: tiles and accordions, new windows placed by `new-window-placement`
    case tiling
    /// Columns on a strip that is longer than the screen, the screen shows the most recent column
    case scrolling
    /// Every window floats, where the user puts it
    case floating
}
