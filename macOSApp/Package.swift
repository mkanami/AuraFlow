// swift-tools-version: 5.9
import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
let privateWallpaperModulesDirectory = packageDirectory
    .appendingPathComponent("Sources/PrivateWallpaperModules")
    .path
let privateFrameworksDirectory = "/System/Library/PrivateFrameworks"
let nativeBridgeFrameworks = ["Wallpaper", "WallpaperTypes"]
let nativeBridgeIsDisabled = ProcessInfo.processInfo.environment["AURAFLOW_DISABLE_NATIVE_BRIDGE"] == "1"
let canBuildNativeBridge = !nativeBridgeIsDisabled && nativeBridgeFrameworks.allSatisfy { framework in
    FileManager.default.fileExists(
        atPath: "\(privateFrameworksDirectory)/\(framework).framework"
    )
}

var products: [Product] = [
    .executable(name: "WallpaperControlApp", targets: ["WallpaperControlApp"]),
    .executable(name: "AuraWallpaperAgent", targets: ["AuraWallpaperAgent"]),
]

var targets: [Target] = [
    .target(
        name: "AuraWallpaperCore",
        path: "Sources/AuraWallpaperCore"
    ),
    .executableTarget(
        name: "AuraWallpaperAgent",
        dependencies: ["AuraWallpaperCore"],
        path: "Sources/AuraWallpaperAgent"
    ),
    .executableTarget(
        name: "WallpaperControlApp",
        dependencies: [
            "AuraWallpaperCore",
        ],
        exclude: ["WallpaperControlApp.entitlements"],
        resources: [
            .process("Resources")
        ]
    ),
    .testTarget(
        name: "WallpaperControlAppTests",
        dependencies: [
            "AuraWallpaperCore",
            "WallpaperControlApp",
            "AuraWallpaperAgent",
        ],
        path: "Tests/WallpaperControlAppTests",
        resources: [
            .process("Fixtures")
        ]
    ),
]

if canBuildNativeBridge {
    products.append(
        .executable(
            name: "AuraWallpaperNativeBridge",
            targets: ["AuraWallpaperNativeBridge"]
        )
    )
    targets.append(
        .executableTarget(
            name: "AuraWallpaperNativeBridge",
            dependencies: ["AuraWallpaperCore"],
            path: "Sources/AuraWallpaperNativeBridge",
            swiftSettings: [
                .unsafeFlags([
                    "-I",
                    privateWallpaperModulesDirectory,
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F\(privateFrameworksDirectory)",
                    "-framework",
                    "Wallpaper",
                    "-framework",
                    "WallpaperTypes",
                ]),
            ]
        )
    )
}

let package = Package(
    name: "WallpaperControlApp",
    platforms: [
        .macOS(.v13),
    ],
    products: products,
    targets: targets
)
