import CoreImage

enum WallpaperEffectsFilters {
    /// Build new filters when preferences change; mutating filters attached to a layer is undefined.
    static func make(settings: WallpaperEffectsSettings) -> [CIFilter] {
        guard settings.enabled else { return [] }
        var result: [CIFilter] = []
        if settings.blurEnabled && settings.blurAmount > 0,
           let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: settings.blurAmount * 18]) {
            blur.name = "wallpaperBlur"
            result.append(blur)
        }
        if settings.bloomEnabled && settings.bloomIntensity > 0,
           let bloom = CIFilter(name: "CIBloom", parameters: [kCIInputRadiusKey: 4 + settings.bloomRadius * 36,
                                                            kCIInputIntensityKey: settings.bloomIntensity]) {
            bloom.name = "wallpaperBloom"
            result.append(bloom)
        }
        return result
    }
}
