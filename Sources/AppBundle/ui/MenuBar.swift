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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if viewModel.axPermissionStatus != .granted {
                permissionCallout
            } else {
                if viewModel.lastReloadConfigContainedWarnings {
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
        // The persistent but empty and invisible workspaces are just noise
        let workspaces = viewModel.workspaces.filter { !$0.isEffectivelyEmpty || $0.isVisible || $0.isFocused }
        VStack(alignment: .leading, spacing: 6) {
            Text("Workspaces")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(workspaces, id: \.name) { WorkspaceTile(workspace: $0) }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { SettingsWindowController.shared.show() } label: { Label("Settings…", systemImage: "gearshape") }
                .help("Shortcuts, window rules, gaps, the focus border, …")
            Spacer()
            Button {
                Task.startUnstructured {
                    terminationHandler?.beforeTermination()
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
        HStack(spacing: 8) {
            getExperimentalUISettingsMenu(viewModel: viewModel)
                .menuStyle(.borderlessButton)
                .controlSize(.small) // The menu is an AppKit control, it ignores the font
                .fixedSize()
            Spacer(minLength: 8)
            Link("Based on AeroSpace (MIT)", destination: URL(string: "https://github.com/nikitabobko/AeroSpace").orDie())
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize()
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
    @State private var isHovered = false

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
            .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(workspace.isFocused ? Color.accentColor : .clear, lineWidth: 1.5)
            }
            .overlay(alignment: .topTrailing) {
                if workspace.hasFullscreenWindows {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 8, weight: .bold))
                        .padding(5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(workspace.name + workspace.suffix)
    }

    private var background: Color {
        switch true {
            case workspace.isFocused: Color.accentColor.opacity(0.22)
            case isHovered: Color.primary.opacity(0.10)
            case workspace.isVisible: Color.primary.opacity(0.08)
            default: Color.primary.opacity(0.04)
        }
    }
}

/// The icons of the apps in the workspace tiles. The body of the tiles is evaluated on every update of the tray model,
/// the icon lookup (file system, IconServices) runs once per app. The system icon is lazy and multi resolution: with its
/// size set to the tile size, only the small representation is ever rendered
@MainActor
private enum AppIconCache {
    static let size: CGFloat = 14
    private static var icons: [URL: NSImage] = [:]

    static func icon(_ url: URL) -> NSImage {
        if let icon = icons[url] { return icon }
        if icons.count >= 64 { icons.removeAll() } // Apps that were used once. Rebuilding is cheap
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: size, height: size)
        icons[url] = icon
        return icon
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
