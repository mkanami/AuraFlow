import SwiftUI

struct ControlPanel: View {
    @Environment(\.adaptiveGlassAppearance) private var appearance
    @Environment(\.terminalPreviewTitle) private var terminalPreviewTitle
    @ObservedObject var viewModel: AppViewModel
    @Binding var isAdjustingSpeed: Bool
    @Binding var showsWallpaperSourcePicker: Bool
    let panelWidth: CGFloat
    let isCompactBySize: Bool
    let isVeryCompactByHeight: Bool

    private var horizontalInset: CGFloat { isCompactBySize ? 18 : 22 }
    private var verticalInset: CGFloat { isVeryCompactByHeight ? 10 : (isCompactBySize ? 12 : 14) }
    private var rowSpacing: CGFloat { isVeryCompactByHeight ? 8 : (isCompactBySize ? 10 : 12) }
    private var compactTitles: Bool {
        MainControlRowLayout.usesCompactTitles(contentWidth: panelWidth - horizontalInset * 2)
    }
    private var previewTitle: String {
        if let terminalPreviewTitle { return terminalPreviewTitle }
        if viewModel.wallpaperEngine.selection.kind == .web,
           let project = viewModel.wallpaperEngine.selectedProject { return project.title }
        return viewModel.selectedVideoName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            if !isVeryCompactByHeight {
                Text(previewTitle)
                    .font(.caption)
                    .foregroundStyle(appearance.bottomTextTone.secondaryTextColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            MainControlRowLayout(row: .playback) {
                startButton
                lockButton
                playbackButton
                removeButton
                changeButton
            }

            MainControlRowLayout(row: .library) {
                catalogButton
                downloadedButton
                terminalButton
                settingsButton
                monitoringButton
            }

            if !isVeryCompactByHeight, panelWidth >= 860, let message = viewModel.statusMessage {
                Text(UserFacingMessageFormatter.format(message))
                    .foregroundStyle(appearance.bottomTextTone.secondaryTextColor)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !isVeryCompactByHeight, panelWidth >= 820, viewModel.optimizationInProgress {
                VStack(alignment: .leading, spacing: 6) {
                    if let label = viewModel.optimizationLabel {
                        Text(UserFacingMessageFormatter.format(label))
                            .font(.caption)
                            .foregroundStyle(appearance.bottomTextTone.secondaryTextColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    ProgressView(value: viewModel.optimizationProgress)
                        .progressViewStyle(.linear)
                }
            }
        }
        .controlSize(.regular)
        .padding(.vertical, verticalInset)
        .padding(.horizontal, horizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AuraGlassRoundedSurface(
            cornerRadius: 14,
            material: .clear,
            alphaMultiplier: appearance.bottomGlassAlpha,
            protectionOverlayOpacity: appearance.bottomProtectionOverlayOpacity,
            protectionOverlayColor: appearance.bottomTextTone.contrastSurfaceColor
        ))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.white.opacity(0.14), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 2)
        .environment(\.colorScheme, .dark)
    }

    private var startButton: some View {
        MainPanelActionButton("Start", icon: "desktopcomputer", id: "start",
                              help: "Apply wallpaper to desktop and Lock Screen", enabled: viewModel.canStart) {
            viewModel.start()
        }
    }

    private var lockButton: some View {
        MainPanelActionButton("Lock", icon: "lock.display", id: "lock",
                              help: "Apply wallpaper to Lock Screen only", enabled: viewModel.canApplyLockScreenOnly) {
            viewModel.applyLockScreenOnly()
        }
    }

    private var playbackButton: some View {
        MainPanelActionButton(viewModel.isPlaybackPaused ? "Resume" : "Stop",
                              icon: viewModel.playbackButtonSystemImage, id: "playback",
                              help: viewModel.isPlaybackPaused ? "Resume wallpaper" : "Stop wallpaper",
                              enabled: viewModel.canTogglePlayback,
                              role: viewModel.isPlaybackPaused ? nil : .destructive) {
            viewModel.togglePlayback()
        }
    }

    private var removeButton: some View {
        MainPanelActionButton("Remove", id: "remove", help: "Remove the active wallpaper",
                              enabled: viewModel.canClearWallpaper, role: .destructive) {
            viewModel.clearWallpaper()
        }
    }

    private var changeButton: some View {
        MainPanelActionButton(compactTitles ? "Change…" : "Change Wallpaper…", id: "change",
                              help: "Choose video or image, or import Wallpaper Engine",
                              enabled: viewModel.canClearWallpaper,
                              accessibilityTitle: "Change Wallpaper") {
            showsWallpaperSourcePicker.toggle()
        }
        .anchorPreference(key: WallpaperSourceButtonAnchorKey.self, value: .bounds) { $0 }
    }

    private var catalogButton: some View {
        MainPanelActionButton(compactTitles ? "Catalog" : "Wallpaper Catalog", id: "catalog",
                              help: "Browse the wallpaper catalog", enabled: viewModel.canClearWallpaper,
                              accessibilityTitle: "Wallpaper Catalog") {
            viewModel.openCatalog()
        }
    }

    private var downloadedButton: some View {
        MainPanelActionButton(compactTitles ? "Downloaded" : "Downloaded Wallpapers", id: "downloaded",
                              help: "Open downloaded and imported wallpapers", enabled: viewModel.canClearWallpaper,
                              accessibilityTitle: "Downloaded Wallpapers") {
            viewModel.openDownloadedWallpapers()
        }
    }

    private var terminalButton: some View {
        MainPanelActionButton(compactTitles ? "Terminal" : "Terminal Wallpaper", icon: "terminal", id: "terminal",
                              help: "Choose a terminal animation", accessibilityTitle: "Terminal Wallpaper") {
            viewModel.openTerminalWallpaper()
        }
    }

    private var settingsButton: some View {
        MainPanelActionButton("Settings", icon: "slider.horizontal.3", id: "settings", help: "Playback Settings",
                              enabled: !viewModel.isBusy, iconOnly: true) {
            viewModel.openSettings()
        }
    }

    private var monitoringButton: some View {
        MainPanelActionButton("Monitoring", icon: "gauge.with.dots.needle.67percent", id: "monitoring",
                              help: "Open performance monitoring", enabled: viewModel.canOpenMonitoring, iconOnly: true) {
            viewModel.openMonitoring()
        }
    }
}

/// Sizing is inside the button style so the entire 32-point glass surface is clickable.
struct MainPanelActionButton: View {
    let title: String
    var icon: String? = nil
    let id: String
    let help: String
    var enabled = true
    var iconOnly = false
    var role: ButtonRole? = nil
    var accessibilityTitle: String? = nil
    let action: () -> Void

    init(_ title: String, icon: String? = nil, id: String, help: String,
         enabled: Bool = true, iconOnly: Bool = false, role: ButtonRole? = nil,
         accessibilityTitle: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.id = id
        self.help = help
        self.enabled = enabled
        self.iconOnly = iconOnly
        self.role = role
        self.accessibilityTitle = accessibilityTitle
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Group {
                if let icon {
                    if iconOnly { Image(systemName: icon) }
                    else { Label(title, systemImage: icon) }
                } else { Text(title) }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(AuraPanelButtonStyle(height: MainControlRowLayout.buttonHeight,
                                        horizontalPadding: iconOnly ? 0 : 12))
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(accessibilityTitle ?? title)
        .accessibilityIdentifier("mainPanel.\(id)")
    }
}
