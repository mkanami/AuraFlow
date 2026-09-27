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
    .executable(name: "AuraTerminalWallpaperAgent", targets: ["AuraTerminalWallpaperAgent"]),
]

var targets: [Target] = [
    .target(
        name: "AuraTerminalPTYKit",
        path: "Sources/AuraTerminalPTYKit",
        publicHeadersPath: "include"
    ),
    .target(
        name: "AuraTerminalWallpaperCore",
        dependencies: ["AuraTerminalPTYKit"],
        path: "Sources/AuraTerminalWallpaperCore"
    ),
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
        name: "AuraTerminalWallpaperAgent",
        dependencies: ["AuraTerminalWallpaperCore"],
        path: "Sources/AuraTerminalWallpaperAgent",
        swiftSettings: canBuildNativeBridge ? [.unsafeFlags(["-I", privateWallpaperModulesDirectory])] : [],
        linkerSettings: canBuildNativeBridge ? [.unsafeFlags([
            "-F\(privateFrameworksDirectory)",
            "-Xlinker", "-weak_framework", "-Xlinker", "Wallpaper",
            "-Xlinker", "-weak_framework", "-Xlinker", "WallpaperTypes",
        ])] : []
    ),
    .executableTarget(
        name: "WallpaperControlApp",
        dependencies: [
            "AuraWallpaperCore",
            "AuraTerminalWallpaperCore",
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
            "AuraTerminalWallpaperCore",
            "WallpaperControlApp",
            "AuraWallpaperAgent",
            "AuraTerminalWallpaperAgent",
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
