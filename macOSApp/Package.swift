// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WallpaperControlApp",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "WallpaperControlApp", targets: ["WallpaperControlApp"]),
        .executable(name: "AuraWallpaperAgent", targets: ["AuraWallpaperAgent"]),
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
