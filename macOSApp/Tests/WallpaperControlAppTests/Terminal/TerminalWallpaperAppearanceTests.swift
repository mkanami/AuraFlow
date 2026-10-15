import Testing
@testable import WallpaperControlApp

@Test func terminalWallpaperLightBackingIsLocallyReduced() {
    let original = AdaptiveGlassAppearance.safeFallback
    let adjusted = terminalWallpaperPopupAppearance(from: original)

    #expect(adjusted.centerProtectionOverlayOpacity == 0.22)
    #expect(adjusted.centerTextTone == original.centerTextTone)
    #expect(adjusted.topProtectionOverlayOpacity == original.topProtectionOverlayOpacity)
    #expect(adjusted.bottomProtectionOverlayOpacity == original.bottomProtectionOverlayOpacity)
    #expect(original.centerProtectionOverlayOpacity == 0.58)
}

@Test func terminalWallpaperDarkBackingKeepsSharedAppearance() {
    let original = AdaptiveGlassAppearance.emptyState
    #expect(terminalWallpaperPopupAppearance(from: original) == original)
}

@Test func terminalWallpaperDoesNotBrightenAlreadySubtleBacking() {
    let original = AdaptiveGlassAppearance.previewTransitionFallback
    #expect(terminalWallpaperPopupAppearance(from: original) == original)
}
