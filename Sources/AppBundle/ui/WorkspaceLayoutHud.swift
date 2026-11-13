import AppKit
import Common
import SwiftUI

/// Tells which layout the workspace is in after `workspace-layout` switched it (Omarchy shows a notification): the three
/// layouts on the monitor of the workspace, the current one highlighted. It fades out by itself, a switch meanwhile
/// shows the new layout in the same place
final class WorkspaceLayoutHud: NSPanelHud {
    @MainActor static let shared = WorkspaceLayoutHud()
    private var hideTask: Task<Void, Never>? = nil
    private let host = NSHostingView(rootView: WorkspaceLayoutHudView(workspace: "", layout: .tiling))

    override private init() {
        super.init()
        ignoresMouseEvents = true
        hasShadow = false // The view draws its own
        contentView = host
    }

    @MainActor
    func show(_ layout: WorkspaceLayout, of workspace: Workspace) {
        host.rootView = WorkspaceLayoutHudView(workspace: workspace.name, layout: layout)
        let size = host.fittingSize
        // Monitor rects have their origin in the top left corner of the main monitor, AppKit in the bottom left one
        let screen = workspace.workspaceMonitorInfo.visibleRect
        let bottom = screen.maxY - screen.height * 0.18
        setFrame(
            NSRect(x: screen.minX + (screen.width - size.width) / 2, y: mainMonitorInfo.height - bottom, width: size.width, height: size.height),
            display: true,
        )
        hideTask?.cancel()
        if !isVisible || alphaValue < 1 {
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
        }
        hideTask = Task.startUnstructured { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard let self, !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.3; self.animator().alphaValue = 0 }
            if !Task.isCancelled { orderOut(nil) }
        }
    }
}

private struct WorkspaceLayoutHudView: View {
    let workspace: String
    let layout: WorkspaceLayout

    var body: some View {
        VStack(spacing: 8) {
            Text("Workspace \(workspace)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(WorkspaceLayout.allCases, id: \.self) { option in
                    let isCurrent = option == layout
                    VStack(spacing: 5) {
                        Image(systemName: option.symbol)
                            .font(.system(size: 22, weight: .medium))
                            .frame(height: 26)
                        Text(option.title)
                            .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                    }
                    .frame(width: 78, height: 62)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .background(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 11))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(16) // Room for the shadow
        .environment(\.colorScheme, .dark)
    }
}

extension WorkspaceLayout {
    var title: String {
        switch self {
            case .tiling: "Tiling"
            case .scrolling: "Scrolling"
            case .floating: "Floating"
        }
    }

    var symbol: String {
        switch self {
            case .tiling: "rectangle.split.2x2"
            case .scrolling: "rectangle.split.3x1"
            case .floating: "rectangle.on.rectangle"
        }
    }
}
