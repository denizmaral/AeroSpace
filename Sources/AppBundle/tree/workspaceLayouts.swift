import AppKit
import Common

// A workspace tiles, scrolls or floats (`workspace-layout`, see ``WorkspaceLayout``), like Omarchy cycles its workspaces
// through dwindle, scrolling and floating:
// - tiling: the tiling tree, its root container is tiles or an accordion
// - scrolling: its root container scrolls (``Layout/scrolling``), every window is a column
// - floating: every window floats. The windows that the workspace floated are marked (``Window/isFloatedByWorkspaceLayout``):
//   they are tiles again when it stops floating, the windows that float on their own account stay floating
//
// A workspace that leaves tiling or scrolling remembers its tree, and it puts the windows back there when it's in that
// layout again: switching never loses the layout. The trees are remembered in memory (by the windows, not by native ids)

/// What a workspace knows about its layout. Kept by the name of the workspace: an empty workspace that isn't shown is
/// garbage collected, and it keeps its layout when it's used again
struct WorkspaceLayoutMemory {
    /// The layout that `workspace-layout` gave the workspace. nil: the workspace has the default layout
    var chosen: WorkspaceLayout? = nil
    /// The trees of the layouts that the workspace left, as it left them
    var trees: [WorkspaceLayout: TilingTreeSnapshot<OpaqueWindowId>] = [:]
    /// The windows that the floating layout puts in the middle of the screen are stepped from each other
    var cascadeStep = 0
}

@MainActor var workspaceLayoutMemories: [String: WorkspaceLayoutMemory] = [:]

extension Workspace {
    @MainActor var layoutMemory: WorkspaceLayoutMemory {
        get { workspaceLayoutMemories[name] ?? WorkspaceLayoutMemory() }
        set { workspaceLayoutMemories[name] = newValue }
    }

    @MainActor var workspaceLayout: WorkspaceLayout {
        if isFloatingLayout { return .floating }
        return rootTilingContainer.layout == .scrolling ? .scrolling : .tiling
    }

    /// The layout that `workspace-layout` gave the workspace, the default layout otherwise. A tiling or scrolling
    /// workspace is what its root container is: the default applies to new root containers
    @MainActor var chosenOrDefaultLayout: WorkspaceLayout { layoutMemory.chosen ?? config.defaultWorkspaceLayout }

    @MainActor var isFloatingLayout: Bool { chosenOrDefaultLayout == .floating }

    /// The orientation of a new root container: horizontal on a landscape monitor by default
    @MainActor var defaultRootOrientation: Orientation {
        switch config.defaultRootContainerOrientation {
            case .horizontal: .h
            case .vertical: .v
            case .auto: workspaceMonitorInfo.then { $0.width >= $0.height } ? .h : .v
        }
    }

    /// Switches the layout of the workspace. The tree of the layout that it leaves is remembered, the tree of the layout
    /// that it enters comes back as it was (the windows that aren't there anymore are left out, the windows that are new
    /// to it are placed like new windows)
    @MainActor
    func setWorkspaceLayout(_ target: WorkspaceLayout) {
        let current = workspaceLayout
        guard current != target else { return }
        let windowId: (Window) -> OpaqueWindowId? = { $0.windowId }
        switch current {
            case .tiling, .scrolling:
                layoutMemory.trees[current] = tilingTreeSnapshot(windowId: windowId)
            case .floating:
                layoutMemory.chosen = target // Not floating anymore: the windows are tiles again
                for window in floatingWindows where window.isFloatedByWorkspaceLayout {
                    window.stopFloatingByWorkspaceLayout()
                    window.bindAsNewTilingWindow(to: self)
                }
                for window in rootTilingContainer.allLeafWindowsRecursive where window.tiledOnFloatingWorkspace === self {
                    window.tiledOnFloatingWorkspace = nil
                }
        }
        layoutMemory.chosen = target
        switch target {
            case .floating:
                for window in rootTilingContainer.allLeafWindowsRecursive {
                    window.floatByWorkspaceLayout(on: self)
                }
            case .tiling, .scrolling:
                // The tree of the other layout gives the order of the windows if the workspace wasn't in this one yet
                if let tree = layoutMemory.trees[target] ?? layoutMemory.trees[target == .tiling ? .scrolling : .tiling] {
                    restoreTilingTree(tree, windowId: windowId)
                }
                let root = rootTilingContainer
                switch target {
                    case .scrolling where root.layout != .scrolling: makeEveryWindowAColumn()
                    case .tiling where root.layout == .scrolling: root.layout = config.defaultRootContainerLayout.tilingLayout
                    case .tiling, .scrolling, .floating: break
                }
        }
    }

    /// Scrolling for the first time: every tiling window is a column, in the order of the tree
    @MainActor
    private func makeEveryWindowAColumn() {
        let previousRoot = rootTilingContainer
        let windows = previousRoot.allLeafWindowsRecursive
        let mostRecent = previousRoot.mostRecentWindowRecursive
        previousRoot.unbindFromParent()
        let root = TilingContainer(parent: self, adaptiveWeight: 1, defaultRootOrientation, .scrolling, index: INDEX_BIND_LAST)
        for window in windows {
            window.dwindleSplitAnchor = nil // The windows are columns, nobody gives its weight back
            window.bind(to: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        }
        mostRecent?.markAsMostRecentChild()
    }

    /// The tiling windows that came to floating workspaces float (they were opened there, moved there, or came back
    /// from macOS fullscreen), unless the user made them tiles there. The windows that a floating workspace floated and
    /// that were moved to a workspace that doesn't float are tiles there. Called by the refresh sessions, after the
    /// window rules: a rule that floats a window floats it on its own account
    @MainActor
    static func applyFloatingLayouts() {
        for workspace in Workspace.all {
            if workspace.isFloatingLayout {
                for window in workspace.rootTilingContainer.allLeafWindowsRecursive where window.tiledOnFloatingWorkspace !== workspace {
                    window.floatByWorkspaceLayout(on: workspace)
                }
            } else {
                // Doesn't create the floating container (the getter of floatingWindows does)
                let floating = workspace.children.lazy.compactMap { $0 as? FloatingWindowsContainer }.first?.children ?? []
                for case let window as Window in floating where window.isFloatedByWorkspaceLayout {
                    window.stopFloatingByWorkspaceLayout()
                    window.bindAsNewTilingWindow(to: workspace)
                }
            }
        }
    }

    /// Where the floating layout puts a window that was a tile: in the middle of the screen at a comfortable size (the
    /// size that Omarchy gives it), stepped from the window before so that windows floated together don't cover each other
    @MainActor
    fileprivate func nextCascadeFrame() -> Rect {
        let screen = workspaceMonitorInfo.visibleRect
        let width = min(1100, (screen.width * 0.64).rounded())
        let height = min(760, (screen.height * 0.68).rounded())
        let step = CGFloat(layoutMemory.cascadeStep * 24 - 48)
        layoutMemory.cascadeStep = (layoutMemory.cascadeStep + 1) % 5
        return Rect(
            topLeftX: (screen.minX + (screen.width - width) / 2 + step).rounded(),
            topLeftY: (screen.minY + (screen.height - height) / 2 + step).rounded(),
            width: width,
            height: height,
        )
    }
}

extension Layout {
    /// The layout of the root container of a workspace that tiles
    fileprivate var tilingLayout: Layout { self == .scrolling ? .tiles : self }
}

extension Window {
    /// The floating workspace floats the window: where it was the last time the workspace floated, otherwise in the
    /// middle of the screen
    @MainActor
    func floatByWorkspaceLayout(on workspace: Workspace) {
        isFloatedByWorkspaceLayout = true
        tiledOnFloatingWorkspace = nil
        isFullscreen = false // The frame of the floating layout
        tilingSlot = nil // The remembered tree of the workspace has its place
        bindAsFloatingWindow(to: workspace)
        let screen = workspace.workspaceMonitorInfo.visibleRect
        if let frame = floatingFrameOfWorkspaceLayout, screen.contains(frame.center) {
            floatingFrameToApply = frame
        } else {
            floatingFrameToApply = workspace.nextCascadeFrame()
        }
    }

    /// The window floats on its own account from now on, or it's about to be a tile again
    @MainActor
    func stopFloatingByWorkspaceLayout() {
        guard isFloatedByWorkspaceLayout else { return }
        isFloatedByWorkspaceLayout = false
        if floatingFrameToApply == nil, let frame = observedFrame { floatingFrameOfWorkspaceLayout = frame }
        floatingFrameToApply = nil
    }
}
