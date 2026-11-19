import Foundation

/// SwiftPM's generated accessor searches beside the executable's main bundle,
/// which misses Contents/Resources in a distributed macOS app (issue #17).
enum AppResources {
    static let bundleName = "WallpaperControlApp_WallpaperControlApp"
    static let jsonResources = [
        "desktophut-api", "livewallpapers4free-api", "livelywallpaper-api",
        "catalog-content-exclusions", "music-catalog-review", "music-catalog-seeds",
    ]
    static let bundle = resolveBundle()

    static func resolveBundle(
        mainBundle: Bundle = .main,
        packageBundle: () -> Bundle = { .module }
    ) -> Bundle? {
        if let url = mainBundle.resourceURL?
            .appendingPathComponent("\(bundleName).bundle", isDirectory: true),
           let embedded = Bundle(url: url) {
            return embedded
        }
        // A packaged app must be self-contained. Never let a local .build
        // directory hide missing resources or invoke SwiftPM's fatalError.
        guard mainBundle.bundleURL.pathExtension != "app" else { return nil }
        return packageBundle()
    }

    @discardableResult
    static func validate(bundle: Bundle? = AppResources.bundle) throws -> Bundle {
        guard let bundle else { throw ResourceError.missingBundle }
        for name in jsonResources {
            guard let url = bundle.url(forResource: name, withExtension: "json") else {
                throw ResourceError.missingFile("\(name).json")
            }
            do {
                _ = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            } catch {
                throw ResourceError.unreadableFile("\(name).json")
            }
        }
        return bundle
    }

    enum ResourceError: LocalizedError {
        case missingBundle
        case missingFile(String)
        case unreadableFile(String)

        var errorDescription: String? {
            let cause: String
            switch self {
            case .missingBundle: cause = "AuraFlow's application resources are missing."
            case .missingFile(let name): cause = "AuraFlow's application resource \(name) is missing."
            case .unreadableFile(let name): cause = "AuraFlow's application resource \(name) is unreadable or damaged."
            }
            return "\(cause) Download AuraFlow again and copy the entire AuraFlow.app from the disk image to Applications."
        }
    }
}
