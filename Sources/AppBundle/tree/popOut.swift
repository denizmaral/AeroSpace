import AppKit
import Common

/// What a popped out window was before `pop-out` (see ``PopOutCommand``): it goes back to it when it's popped back in
enum PoppedOutOrigin: Equatable, Sendable {
    /// A tile: the window remembers its place in the tree (``Window/tilingSlot``)
    case tile
    /// A floating window, at this frame (nil: unknown, e.g. MarSpace was restarted meanwhile: it stays where it is)
    case floating(Rect?)
}

extension Window {
    /// Popped out, and still floating and pinned: `layout tiling` or `pin off` ended it
    @MainActor
    var isPoppedOut: Bool { poppedOut != nil && isPinned && parent is FloatingWindowsContainer }

    /// Floating, pinned, in the middle of its monitor (Omarchy's "pop window out"): where it was the last time it was
    /// popped out, otherwise 1300 by 900 points, at most nine tenths of the screen
    @MainActor
    func popOut(on workspace: Workspace) {
        if parent is TilingContainer {
            poppedOut = .tile
            bindAsFloatingWindowRememberingTilingSlot(to: workspace)
        } else {
            poppedOut = .floating(observedFrame)
        }
        stopFloatingByWorkspaceLayout() // It floats on its own account, and comes along to other workspaces
        isPinned = true
        isFullscreen = false
        let screen = workspace.workspaceMonitorInfo.visibleRect
        if let frame = lastPoppedOutFrame, screen.contains(frame.center), frame.width <= screen.width, frame.height <= screen.height {
            floatingFrameToApply = frame
        } else {
            let width = min(1300, (screen.width * 0.9).rounded())
            let height = min(900, (screen.height * 0.9).rounded())
            floatingFrameToApply = Rect(
                topLeftX: (screen.minX + (screen.width - width) / 2).rounded(),
                topLeftY: (screen.minY + (screen.height - height) / 2).rounded(),
                width: width,
                height: height,
            )
        }
    }

    /// Back to what it was: its tile (a new one if it came along to another workspace), the frame where it floated, or a
    /// floating window like the others on a floating workspace
    @MainActor
    func popIn(on workspace: Workspace) async throws {
        let origin = poppedOut
        poppedOut = nil
        isPinned = false
        if let frame = floatingFrameToApply ?? observedFrame { lastPoppedOutFrame = frame }
        floatingFrameToApply = nil
        switch origin {
            case .floating(let frame?): setAxFrame(frame.topLeftCorner, frame.size)
            case .floating(nil), nil: break // It stays where it is
            case .tile where workspace.isFloatingLayout: floatByWorkspaceLayout(on: workspace)
            case .tile: try await tileFloatingWindow(on: workspace)
        }
    }
}
