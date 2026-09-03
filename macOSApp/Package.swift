// swift-tools-version: 5.9
import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
let privateWallpaperModulesDirectory = packageDirectory
    .appendingPathComponent("Sources/PrivateWallpaperModules")
    .path

let package = Package(
    name: "WallpaperControlApp",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "WallpaperControlApp", targets: ["WallpaperControlApp"]),
        .executable(name: "AuraWallpaperAgent", targets: ["AuraWallpaperAgent"]),
        .executable(
            name: "AuraWallpaperNativeBridge",
            targets: ["AuraWallpaperNativeBridge"]
        ),
    ],
    targets: [
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
                    "-F/System/Library/PrivateFrameworks",
                    "-framework",
                    "Wallpaper",
                    "-framework",
                    "WallpaperTypes",
                ]),
            ]
        ),
        .executableTarget(
            name: "WallpaperControlApp",
            dependencies: [
                "AuraWallpaperCore",
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "WallpaperControlAppTests",
            dependencies: [
                "AuraWallpaperCore",
                "WallpaperControlApp",
            ],
            path: "Tests/WallpaperControlAppTests",
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
