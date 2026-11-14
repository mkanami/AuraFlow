import SwiftUI

/// Scroll bookkeeping does not publish view changes. Card appearance must not
/// invalidate the whole lazy grid just to update a set of visible IDs.
@MainActor
private final class CatalogGridViewport: ObservableObject {
    var visibleIDs = Set<String>()
}

struct WallpaperCatalogGridView: View {
    let viewModel: AppViewModel
    @ObservedObject var catalogViewModel: CatalogViewModel
    @StateObject private var posterPrefetcher = CatalogPosterPrefetcher()
    @StateObject private var viewport = CatalogGridViewport()

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]

    var body: some View {
        ScrollViewReader { scrollViewProxy in
            ScrollView {
                groupedWallpaperCards
                    .padding(.vertical, 2)

                ZStack {
                    if catalogViewModel.isLoadingMore {
                        ProgressView().controlSize(.small)
                    } else if catalogViewModel.canLoadMore {
                        Button(action: viewModel.loadMoreCatalogWallpapers) {
                            Label(catalogViewModel.loadMoreFailed ? "Try again" : "Load more", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(AuraGlassButtonStyle(fillWidth: false, compact: true))
                        .disabled(catalogViewModel.isRefreshing)
                        .accessibilityIdentifier("catalog.loadMore")
                        .onAppear { requestMoreIfNearEnd() }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
            }
            .onChange(of: catalogViewModel.scrollRequestGeneration) { _ in
                guard let targetID = catalogViewModel.scrollTargetID else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    scrollViewProxy.scrollTo(targetID, anchor: .top)
                }
            }
            .onChange(of: catalogViewModel.isRefreshing) { refreshing in
                if !refreshing { requestMoreIfNearEnd() }
            }
            .onChange(of: catalogViewModel.isLoadingMore) { loading in
                if !loading { requestMoreIfNearEnd() }
            }
            .onChange(of: catalogViewModel.filteredWallpapers.map(\.id)) { ids in
                viewport.visibleIDs.formIntersection(ids)
                requestMoreIfNearEnd()
            }
            .onChange(of: catalogViewModel.showsMusicOnly) { _ in requestMoreIfNearEnd() }
            .onChange(of: catalogViewModel.selectedGroup) { _ in requestMoreIfNearEnd() }
            .onChange(of: catalogViewModel.selectedWallpaper?.id) { id in
                if id == nil { requestMoreIfNearEnd() }
            }
            .onDisappear { viewport.visibleIDs = []; posterPrefetcher.cancel() }
        }
    }

    @ViewBuilder
    private var groupedWallpaperCards: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                wallpaperCards
            }
        } else {
            wallpaperCards
        }
        #else
        wallpaperCards
        #endif
    }

    private var wallpaperCards: some View {
        let wallpapers = catalogViewModel.filteredWallpapers
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(wallpapers) { wallpaper in
                CatalogWallpaperCard(wallpaper: wallpaper, audioMetadata: viewModel.catalogAudioMetadata,
                    localURL: viewModel.downloadedCatalogWallpapers.first { $0.wallpaperID == wallpaper.id }?.localURL) {
                    viewModel.openCatalogWallpaper(wallpaper)
                }
                .equatable()
                .id(wallpaper.id)
                .onAppear {
                    viewport.visibleIDs.insert(wallpaper.id)
                    posterPrefetcher.setVisible(wallpaper.id, true)
                    requestMoreIfNearEnd()
                }
                .onDisappear {
                    viewport.visibleIDs.remove(wallpaper.id)
                    posterPrefetcher.setVisible(wallpaper.id, false)
                }
            }
        }
        .onAppear { posterPrefetcher.update(wallpapers: wallpapers) }
        .onChange(of: wallpapers) { posterPrefetcher.update(wallpapers: $0) }
    }

    private func requestMoreIfNearEnd() {
        guard catalogViewModel.canLoadMore, !catalogViewModel.isLoadingMore,
              !catalogViewModel.automaticPaginationPaused, !catalogViewModel.loadMoreFailed else { return }
        let items = catalogViewModel.filteredWallpapers
        guard let trailingID = items.last?.id else {
            viewModel.loadMoreCatalogWallpapers()
            return
        }
        if !viewport.visibleIDs.isDisjoint(with: items.suffix(6).map(\.id)) {
            viewModel.catalogTrailingWallpaperBecameVisible(trailingID)
        }
    }
}

struct CatalogWallpaperCard: View, Equatable {
    let wallpaper: CatalogWallpaper
    let audioMetadata: CatalogAudioMetadata
    var localURL: URL? = nil
    let action: () -> Void
    @Environment(\.adaptiveGlassAppearance) private var adaptiveGlassAppearance

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.wallpaper == rhs.wallpaper && lhs.localURL == rhs.localURL && lhs.audioMetadata === rhs.audioMetadata
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                CatalogPreviewImage(
                    url: wallpaper.previewImageURL,
                    title: wallpaper.title,
                    referer: wallpaper.sourcePageURL
                )
                .frame(height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    CatalogWallpaperAudioBadge(id: wallpaper.id, metadata: audioMetadata).padding(6)
                }

                Text(wallpaper.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(adaptiveGlassAppearance.bottomTextTone.primaryTextColor)
                    .lineLimit(1)
                Text(wallpaper.category)
                    .font(.caption)
                    .foregroundStyle(adaptiveGlassAppearance.bottomTextTone.secondaryTextColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .modifier(CatalogWallpaperCardGlass())
            .contentShape(Rectangle())
        }
        .buttonStyle(AuraPlainPressButtonStyle())
        .accessibilityIdentifier("catalog-card-\(wallpaper.id)")
        .task(id: localURL?.absoluteString ?? wallpaper.id) {
            // Browsing is poster-only. Unknown remote audio is inspected by
            // the detail view, never by hundreds of cards passing the viewport.
            guard wallpaper.hasMusic == true || localURL != nil else { return }
            // Let a fast-moving row pass before inspecting a local download.
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            await audioMetadata.inspect(wallpaper, localURL: localURL)
        }
    }
}

private struct CatalogWallpaperCardGlass: ViewModifier {
    @Environment(\.adaptiveGlassAppearance) private var appearance

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Group {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                // Apply glass to the whole label so its image and text remain
                // foreground content rather than entering the backdrop sample.
                content.glassEffect(.clear.interactive(), in: shape)
            } else {
                content.background(AuraGlassRoundedSurface(
                    cornerRadius: 10,
                    alphaMultiplier: appearance.bottomGlassAlpha,
                    protectionOverlayOpacity: appearance.bottomProtectionOverlayOpacity * 0.35,
                    protectionOverlayColor: appearance.bottomTextTone.contrastSurfaceColor
                ))
            }
            #else
            content.background(AuraGlassRoundedSurface(
                cornerRadius: 10,
                alphaMultiplier: appearance.bottomGlassAlpha,
                protectionOverlayOpacity: appearance.bottomProtectionOverlayOpacity * 0.35,
                protectionOverlayColor: appearance.bottomTextTone.contrastSurfaceColor
            ))
            #endif
        }
        .overlay {
            shape.stroke(appearance.bottomTextTone.primaryTextColor.opacity(0.14), lineWidth: 0.8)
        }
        .environment(\.colorScheme, appearance.bottomTextTone.glassColorScheme)
    }
}

