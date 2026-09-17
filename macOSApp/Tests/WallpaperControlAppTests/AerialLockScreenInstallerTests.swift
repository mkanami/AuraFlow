import Darwin
import AVFoundation
import Foundation
import Testing
@testable import AuraWallpaperCore
@testable import WallpaperControlApp

private final class AerialRefreshCounter: @unchecked Sendable {
    private(set) var count = 0
    private(set) var rearmCount = 0
    private(set) var lockSessionHandoffCount = 0

    func increment() {
        count += 1
    }

    func incrementRearm() {
        rearmCount += 1
    }

    func incrementLockSessionHandoff() {
        lockSessionHandoffCount += 1
    }
}

private final class AerialProceedGate: @unchecked Sendable {
    private var remainingAllowedCalls: Int

    init(allowedCalls: Int) {
        remainingAllowedCalls = allowedCalls
    }

    func shouldProceed() -> Bool {
        defer { remainingAllowedCalls -= 1 }
        return remainingAllowedCalls > 0
    }
}

private final class WallpaperStoreSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []

    func append(_ value: Data) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func contains(_ value: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return values.contains(value)
    }

    var last: Data? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }
}

private final class DesktopImageTransitionRecorder: @unchecked Sendable {
    private(set) var appliedURLs: [URL] = []
    private(set) var storeData: Data
    private var activeURL: URL?
    private let targetURL: URL?
    private var timestamp = Date(timeIntervalSince1970: 1_000)
    var failFinalURL: URL?
    var ignoreTemporaryTransition = false
    private(set) var temporaryUsesDistinctFileIdentity = false

    init(storeData: Data, activeURL: URL?) {
        self.storeData = storeData
        self.activeURL = activeURL
        self.targetURL = activeURL
    }

    func operations() -> DesktopImageTransitionOperations {
        let apply: (URL) -> Bool = { [self] url in
            appliedURLs.append(url)
            if appliedURLs.count == 1,
               let targetURL,
               let targetFileNumber = try? FileManager.default
                .attributesOfItem(atPath: targetURL.path)[
                    .systemFileNumber
                ] as? NSNumber,
               let temporaryFileNumber = try? FileManager.default
                .attributesOfItem(atPath: url.path)[
                    .systemFileNumber
                ] as? NSNumber {
                temporaryUsesDistinctFileIdentity =
                    targetFileNumber.int64Value
                    != temporaryFileNumber.int64Value
            }
            if failFinalURL?.standardizedFileURL
                == url.standardizedFileURL {
                return false
            }
            if ignoreTemporaryTransition && appliedURLs.count == 1 {
                return true
            }
            timestamp = timestamp.addingTimeInterval(1)
            storeData = try! testImageWallpaperStoreData(
                url: url,
                timestamp: timestamp
            )
            activeURL = url
            return true
        }
        return DesktopImageTransitionOperations(
            applyToCurrentScreens: apply,
            currentScreensMatch: { [self] url in
                activeURL?.standardizedFileURL == url.standardizedFileURL
            },
            readWallpaperStore: { [self] in storeData },
            pause: { _ in }
        )
    }
}

private final class ConcurrentFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private struct AerialLockScreenFixture {
    static let activeSpaceID =
        "49BAC883-46A3-452D-97ED-8A96BBEDA1B1"
    static let staleSpaceID =
        "E463F460-DA1C-4301-AC48-85776A3C15E2"
    static let displayID =
        "37D8832A-2D66-02CA-B9F7-8F30A301B230"
    static let staleDisplayID =
        "2335F433-2476-462F-B0BA-F7A4DE8FC1E4"
    static let assetID =
        "7C643A39-C0B2-4BA0-8BC2-2EAA47CC580E"
    static let alternateAssetID =
        "44166C39-8566-4ECA-BD16-43159429B52F"
    static let secondAlternateAssetID =
        "80C7B9D0-D9A4-41BB-9E8A-DA676267C50A"

    let root: URL
    let storeURL: URL
    let spacesURL: URL
    let videosURL: URL
    let thumbnailsURL: URL
    let providerURL: URL
    let stateURL: URL
    let assetURL: URL
    let videoURL: URL
    let refreshCounter: AerialRefreshCounter
    let rearmCounter: AerialRefreshCounter
    let lockSessionHandoffCounter: AerialRefreshCounter
    let installer: AerialLockScreenInstaller

    init(
        hasExistingAsset: Bool = true,
        providerHasAsset: Bool = true,
        providerAssetIDs: [String]? = nil,
        downloadedAssetIDs: [String] = [],
        configuredAssetID: String? = Self.assetID,
        onRefresh: ((URL) -> Void)? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AuraFlowModernLockScreen-\(UUID().uuidString)",
                isDirectory: true
            )
        storeURL = root.appendingPathComponent("Index.plist")
        spacesURL = root.appendingPathComponent("spaces.plist")
        videosURL = root.appendingPathComponent("videos", isDirectory: true)
        thumbnailsURL = root.appendingPathComponent(
            "thumbnails",
            isDirectory: true
        )
        providerURL = root.appendingPathComponent(
            "WallpaperAerialsExtension.appex",
            isDirectory: true
        )
        stateURL = root.appendingPathComponent("state", isDirectory: true)
        assetURL = videosURL
            .appendingPathComponent(Self.assetID)
            .appendingPathExtension("mov")
        videoURL = root.appendingPathComponent("wallpaper.mp4")

        try FileManager.default.createDirectory(
            at: videosURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: thumbnailsURL,
            withIntermediateDirectories: true
        )
        let providerResourcesURL = providerURL
            .appendingPathComponent(
                "Contents/Resources",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: providerResourcesURL,
            withIntermediateDirectories: true
        )
        let providerInfo: [String: Any] = [
            "CFBundleIdentifier":
                "com.apple.wallpaper.extension.aerials",
            "EXAppExtensionAttributes": [
                "EXExtensionPointIdentifier": "com.apple.wallpaper",
            ],
        ]
        let providerInfoData = try PropertyListSerialization.data(
            fromPropertyList: providerInfo,
            format: .binary,
            options: 0
        )
        try providerInfoData.write(
            to: providerURL
                .appendingPathComponent("Contents/Info.plist")
        )
        let catalogData = try JSONSerialization.data(
            withJSONObject: [
                "assets": providerHasAsset
                    ? (providerAssetIDs ?? [Self.assetID]).map {
                        ["id": $0]
                    }
                    : [],
            ]
        )
        try catalogData.write(
            to: providerResourcesURL
                .appendingPathComponent("entries.json")
        )
        if hasExistingAsset {
            try Data("original-aerial".utf8).write(to: assetURL)
        }
        for assetID in downloadedAssetIDs where assetID != Self.assetID {
            try Data("downloaded-\(assetID)".utf8).write(
                to: videosURL
                    .appendingPathComponent(assetID)
                    .appendingPathExtension("mov")
            )
        }
        try Data("new-wallpaper".utf8).write(to: videoURL)

        let originalDesktop = Self.makeMode(
            provider: "com.apple.wallpaper.choice.image",
            configuration: [
                "type": "imageFile",
                "url": ["relative": "file:///original.jpg"],
            ]
        )
        let originalIdle = Self.makeMode(
            provider: "com.apple.wallpaper.choice.screen-saver",
            configuration: [
                "module": [
                    "relative":
                        "file:///System/Library/ExtensionKit/Extensions/Ventura.appex",
                ],
            ]
        )
        let managedDesktop = Self.makeMode(
            provider: "com.apple.wallpaper.choice.image",
            configuration: [
                "type": "imageFile",
                "url": [
                    "relative":
                        "file:///Library/Application%20Support/AuraFlow/last_frame.png",
                ],
            ]
        )
        let managedIdle = Self.makeMode(
            provider: "com.apple.wallpaper.choice.screen-saver",
            configuration: [
                "module": [
                    "relative":
                        "file:///Users/test/Library/Screen%20Savers/AuraFlowLockScreen.saver",
                ],
            ]
        )
        let originalContainer: [String: Any] = [
            "Type": "individual",
            "Desktop": originalDesktop,
            "Idle": originalIdle,
        ]
        let managedContainer: [String: Any] = [
            "Type": "individual",
            "Desktop": managedDesktop,
            "Idle": managedIdle,
        ]
        let store: [String: Any] = [
            "AllSpacesAndDisplays": originalContainer,
            "SystemDefault": originalContainer,
            "Displays": [
                Self.displayID: managedContainer,
                Self.staleDisplayID: managedContainer,
            ],
            "Spaces": [
                Self.activeSpaceID: [
                    "Default": managedContainer,
                    "Displays": [
                        Self.displayID: managedContainer,
                        Self.staleDisplayID: managedContainer,
                    ],
                ],
                Self.staleSpaceID: [
                    "Default": managedContainer,
                    "Displays": [
                        Self.displayID: managedContainer,
                    ],
                ],
            ],
        ]
        let storeData = try PropertyListSerialization.data(
            fromPropertyList: store,
            format: .binary,
            options: 0
        )
        try storeData.write(to: storeURL)

        let spaces: [String: Any] = [
            "SpacesDisplayConfiguration": [
                "Management Data": [
                    "Monitors": [[
                        "Display Identifier": Self.displayID,
                        "Current Space": [
                            "uuid": Self.activeSpaceID,
                        ],
                        "Spaces": [[
                            "uuid": Self.activeSpaceID,
                        ]],
                    ]],
                    "SpaceAssignments": [
                        "ManagedSpaceOrdering": [[
                            "ManagedDisplayID": Self.displayID,
                            "ManagedSpaceIDs": [Self.activeSpaceID],
                        ]],
                    ],
                ],
            ],
        ]
        let spacesData = try PropertyListSerialization.data(
            fromPropertyList: spaces,
            format: .binary,
            options: 0
        )
        try spacesData.write(to: spacesURL)

        let counter = AerialRefreshCounter()
        refreshCounter = counter
        let rearmCounter = AerialRefreshCounter()
        self.rearmCounter = rearmCounter
        let lockSessionHandoffCounter = AerialRefreshCounter()
        self.lockSessionHandoffCounter = lockSessionHandoffCounter
        let refreshStoreURL = storeURL
        installer = AerialLockScreenInstaller(
            fileManager: .default,
            wallpaperStoreURL: storeURL,
            spacesPreferencesURL: spacesURL,
            aerialVideosURL: videosURL,
            aerialThumbnailsURL: thumbnailsURL,
            aerialProviderURL: providerURL,
            stateDirectoryURL: stateURL,
            assetID: configuredAssetID,
            refreshSystem: {
                counter.increment()
                onRefresh?(refreshStoreURL)
            },
            rearmSystem: {
                counter.increment()
                rearmCounter.incrementRearm()
                onRefresh?(refreshStoreURL)
            },
            lockSessionHandoffSystem: {
                counter.increment()
                lockSessionHandoffCounter.incrementLockSessionHandoff()
            }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    static func makeMode(
        provider: String,
        configuration: [String: Any]
    ) -> [String: Any] {
        let data = try! PropertyListSerialization.data(
            fromPropertyList: configuration,
            format: .binary,
            options: 0
        )
        return [
            "LastSet": Date(),
            "LastUse": Date(),
            "Content": [
                "Choices": [[
                    "Provider": provider,
                    "Files": [],
                    "Configuration": data,
                ]],
                "Shuffle": "$null",
                "EncodedOptionValues": "$null",
            ],
        ]
    }
}

private enum AerialTestMediaError: Error {
    case writerCouldNotAddInput
    case writerCouldNotStart
    case pixelBufferCouldNotBeCreated
    case frameCouldNotBeAppended
    case writerDidNotComplete
}

private func writeAerialTestVideo(to url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 16,
            AVVideoHeightKey: 16,
        ]
    )
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: 16,
            kCVPixelBufferHeightKey as String: 16,
        ]
    )
    guard writer.canAdd(input) else {
        throw AerialTestMediaError.writerCouldNotAddInput
    }
    writer.add(input)
    guard writer.startWriting() else {
        throw AerialTestMediaError.writerCouldNotStart
    }
    writer.startSession(atSourceTime: .zero)

    while !input.isReadyForMoreMediaData {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        16,
        16,
        kCVPixelFormatType_32ARGB,
        nil,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        writer.cancelWriting()
        throw AerialTestMediaError.pixelBufferCouldNotBeCreated
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
        baseAddress.initializeMemory(
            as: UInt8.self,
            repeating: 0xFF,
            count: 16 * 16 * 4
        )
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    guard adaptor.append(pixelBuffer, withPresentationTime: .zero) else {
        writer.cancelWriting()
        throw AerialTestMediaError.frameCouldNotBeAppended
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw AerialTestMediaError.writerDidNotComplete
    }
}

@Test func aerialMediaPreparerUsesAsyncPrepareAPIForFixture() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    let preparer = AerialMediaPreparer(
        fileManager: .default,
        usesCanonicalWallpaperStore: false,
        preparedCacheDirectoryURL: fixture.stateURL
            .appendingPathComponent("prepared-media", isDirectory: true)
    )

    let preparedURL = try await preparer.prepare(from: fixture.videoURL)

    #expect(preparedURL == fixture.videoURL)
}

@Test func aerialMediaPreparerRejectsMissingAndNonQuickTimeFiles() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    let preparer = AerialMediaPreparer(
        fileManager: .default,
        usesCanonicalWallpaperStore: false,
        preparedCacheDirectoryURL: fixture.stateURL
            .appendingPathComponent("prepared-media", isDirectory: true)
    )
    let missingURL = fixture.root.appendingPathComponent("missing.mov")

    let missingIsCompatible = try await preparer.isCompatible(at: missingURL)
    let nonQuickTimeIsCompatible = try await preparer.isCompatible(
        at: fixture.videoURL
    )

    #expect(!missingIsCompatible)
    #expect(!nonQuickTimeIsCompatible)
}

@Test func restoredWallpaperInsideAuraFlowPathIsNotClassifiedAsManaged() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    let restoredDirectory = fixture.root
        .appendingPathComponent("Restored Wallpapers", isDirectory: true)
    try FileManager.default.createDirectory(
        at: restoredDirectory,
        withIntermediateDirectories: true
    )
    let restoredWallpaperURL = restoredDirectory
        .appendingPathComponent("user-wallpaper.jpg")
    try Data("user-wallpaper".utf8).write(to: restoredWallpaperURL)

    let userDesktop = AerialLockScreenFixture.makeMode(
        provider: WallpaperPlatformConstants.imageProviderID,
        configuration: [
            "type": "imageFile",
            "url": ["relative": restoredWallpaperURL.absoluteString],
        ]
    )
    let userContainer: [String: Any] = [
        "Type": "individual",
        "Desktop": userDesktop,
        "Idle": AerialLockScreenFixture.makeMode(
            provider: WallpaperPlatformConstants.screenSaverProviderID,
            configuration: [
                "module": [
                    "relative":
                        "file:///System/Library/ExtensionKit/Extensions/Ventura.appex",
                ],
            ]
        ),
    ]
    let root: [String: Any] = [
        "AllSpacesAndDisplays": userContainer,
        "SystemDefault": userContainer,
    ]
    let currentData = try PropertyListSerialization.data(
        fromPropertyList: root,
        format: .binary,
        options: 0
    )

    let transaction = WallpaperStoreTransaction(
        fileManager: .default,
        wallpaperStoreURL: fixture.storeURL,
        spacesPreferencesURL: fixture.spacesURL,
        aerialVideosURL: fixture.videosURL
    )

    #expect(!transaction.wallpaperStoreHasManagedDesktop(
        currentData,
        managedAssetID: AerialLockScreenFixture.assetID
    ))
    #expect(transaction.wallpaperStoreHasUserDesktop(
        currentData,
        managedAssetID: AerialLockScreenFixture.assetID
    ))

    let cleanedData = try transaction.cleanedWallpaperStoreData(from: currentData)
    let cleanedRoot = try #require(
        try transaction.propertyListDictionary(from: cleanedData)
    )
    let cleanedContainer = try #require(
        cleanedRoot["AllSpacesAndDisplays"] as? [String: Any]
    )
    let cleanedDesktop = try #require(
        cleanedContainer["Desktop"] as? [String: Any]
    )
    #expect(wallpaperStoreText(cleanedDesktop).contains("user-wallpaper.jpg"))
}

@Test func sharedRemoveIgnoresWallpaperAgentDefaultPlaceholder() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    let defaultMode = AerialLockScreenFixture.makeMode(
        provider: "default",
        configuration: [:]
    )
    let container: [String: Any] = [
        "Type": "individual",
        "Desktop": defaultMode,
    ]
    let root: [String: Any] = [
        "AllSpacesAndDisplays": container,
        "SystemDefault": container,
    ]
    let data = try PropertyListSerialization.data(
        fromPropertyList: root,
        format: .binary,
        options: 0
    )
    let transaction = WallpaperStoreTransaction(
        fileManager: .default,
        wallpaperStoreURL: fixture.storeURL,
        spacesPreferencesURL: fixture.spacesURL,
        aerialVideosURL: fixture.videosURL
    )

    #expect(!transaction.wallpaperStoreHasUserDesktop(
        data,
        managedAssetID: AerialLockScreenFixture.assetID
    ))
}

@Test func sharedRemoveFindsConcreteImageBehindGlobalDefaultPlaceholder() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    let defaultMode = AerialLockScreenFixture.makeMode(
        provider: "default",
        configuration: [:]
    )
    let imageURL = URL(fileURLWithPath: "/Users/test/custom-wallpaper.jpg")
    let imageMode = AerialLockScreenFixture.makeMode(
        provider: WallpaperPlatformConstants.imageProviderID,
        configuration: [
            "type": "imageFile",
            "url": ["relative": imageURL.absoluteString],
        ]
    )
    var imageContent = try #require(imageMode["Content"] as? [String: Any])
    var imageChoices = try #require(
        imageContent["Choices"] as? [[String: Any]]
    )
    imageChoices[0]["Files"] = [["relative": imageURL.absoluteString]]
    imageContent["Choices"] = imageChoices
    var concreteImageMode = imageMode
    concreteImageMode["Content"] = imageContent

    let defaultContainer: [String: Any] = [
        "Type": "individual",
        "Desktop": defaultMode,
    ]
    let concreteContainer: [String: Any] = [
        "Type": "individual",
        "Desktop": concreteImageMode,
    ]
    let root: [String: Any] = [
        "AllSpacesAndDisplays": defaultContainer,
        "SystemDefault": defaultContainer,
        "Spaces": [
            AerialLockScreenFixture.activeSpaceID: [
                "Default": concreteContainer,
            ],
        ],
    ]
    let data = try PropertyListSerialization.data(
        fromPropertyList: root,
        format: .binary,
        options: 0
    )
    let transaction = WallpaperStoreTransaction(
        fileManager: .default,
        wallpaperStoreURL: fixture.storeURL,
        spacesPreferencesURL: fixture.spacesURL,
        aerialVideosURL: fixture.videosURL
    )

    #expect(
        transaction.latestUserSystemWallpaperURL(
            from: data,
            managedAssetID: AerialLockScreenFixture.assetID
        ) == imageURL.absoluteString
    )
}

@Test func sharedDesktopImageRestoreAlwaysTransitionsThroughDistinctURL() throws {
    for fileExtension in ["png", "jpg", "heic"] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AuraFlowDesktopTransition-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let targetURL = root
            .appendingPathComponent("user-wallpaper")
            .appendingPathExtension(fileExtension)
        try Data("image-\(fileExtension)".utf8).write(to: targetURL)
        let existingTargetStore = try testImageWallpaperStoreData(
            url: targetURL,
            timestamp: Date(timeIntervalSince1970: 500)
        )
        let recorder = DesktopImageTransitionRecorder(
            storeData: existingTargetStore,
            activeURL: targetURL
        )

        let restored = WallpaperDesktopSupport
            .reactivateCurrentScreensAfterSharedRemove(
                imagePath: targetURL.path,
                appSupportPath: root.path,
                managedAssetID: AerialLockScreenFixture.assetID,
                wallpaperStoreURL: root.appendingPathComponent("unused.plist"),
                operations: recorder.operations()
            )

        #expect(restored)
        #expect(recorder.appliedURLs.count == 2)
        let temporaryURL = try #require(recorder.appliedURLs.first)
        #expect(
            temporaryURL.standardizedFileURL
                != targetURL.standardizedFileURL
        )
        #expect(
            recorder.appliedURLs.last?.standardizedFileURL
                == targetURL.standardizedFileURL
        )
        #expect(recorder.temporaryUsesDistinctFileIdentity)
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
        #expect(wallpaperStoreText(
            try PropertyListSerialization.propertyList(
                from: recorder.storeData,
                options: [],
                format: nil
            )
        ).contains(targetURL.absoluteString))
    }
}

@Test func failedDesktopImageRestoreKeepsTemporaryRouteForRecovery() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "AuraFlowFailedDesktopTransition-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    let targetURL = root.appendingPathComponent("user-wallpaper.jpg")
    try Data("image".utf8).write(to: targetURL)
    let recorder = DesktopImageTransitionRecorder(
        storeData: try testImageWallpaperStoreData(
            url: targetURL,
            timestamp: Date(timeIntervalSince1970: 500)
        ),
        activeURL: targetURL
    )
    recorder.failFinalURL = targetURL

    let restored = WallpaperDesktopSupport
        .reactivateCurrentScreensAfterSharedRemove(
            imagePath: targetURL.path,
            appSupportPath: root.path,
            managedAssetID: AerialLockScreenFixture.assetID,
            wallpaperStoreURL: root.appendingPathComponent("unused.plist"),
            operations: recorder.operations()
        )

    #expect(!restored)
    #expect(recorder.appliedURLs.count == 2)
    let temporaryURL = try #require(recorder.appliedURLs.first)
    #expect(FileManager.default.fileExists(atPath: temporaryURL.path))
}

@Test func unpersistedTemporaryImageTransitionDoesNotDelayFinalRestore() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "AuraFlowFastDesktopTransition-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    let targetURL = root.appendingPathComponent("user-wallpaper.jpg")
    try Data("image".utf8).write(to: targetURL)
    let recorder = DesktopImageTransitionRecorder(
        storeData: try testImageWallpaperStoreData(
            url: targetURL,
            timestamp: Date(timeIntervalSince1970: 500)
        ),
        activeURL: targetURL
    )
    recorder.ignoreTemporaryTransition = true
    let startedAt = Date()

    let restored = WallpaperDesktopSupport
        .reactivateCurrentScreensAfterSharedRemove(
            imagePath: targetURL.path,
            appSupportPath: root.path,
            managedAssetID: AerialLockScreenFixture.assetID,
            wallpaperStoreURL: root.appendingPathComponent("unused.plist"),
            operations: recorder.operations(),
            temporaryTransitionTimeout: 0.05
        )

    #expect(restored)
    #expect(recorder.appliedURLs.count == 2)
    #expect(Date().timeIntervalSince(startedAt) < 0.5)
}

@Test func sharedRemoveNormalizesPreStartImageBeforeProviderLaunchAndPreservesSystemTransition() async throws {
    let refreshSnapshots = WallpaperStoreSnapshotBox()
    let fixture = try AerialLockScreenFixture(onRefresh: { storeURL in
        if let data = try? Data(contentsOf: storeURL) {
            refreshSnapshots.append(data)
        }
    })
    defer { fixture.cleanup() }

    let targetURL = fixture.root.appendingPathComponent("pre-start-user.jpg")
    try Data("pre-start-user-image".utf8).write(to: targetURL)
    let emptyFilesImageMode = AerialLockScreenFixture.makeMode(
        provider: WallpaperPlatformConstants.imageProviderID,
        configuration: [
            "type": "imageFile",
            "url": ["relative": targetURL.absoluteString],
        ]
    )
    var preStartRoot = try readWallpaperStore(fixture.storeURL)
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        var container = try #require(preStartRoot[key] as? [String: Any])
        container["Desktop"] = emptyFilesImageMode
        preStartRoot[key] = container
    }
    try writeWallpaperStore(preStartRoot, to: fixture.storeURL)

    try await fixture.installer.install(videoURL: fixture.videoURL)

    var systemTransitionRoot = try PropertyListSerialization.propertyList(
        from: testImageWallpaperStoreData(
            url: targetURL,
            timestamp: Date(timeIntervalSince1970: 9_000)
        ),
        options: [],
        format: nil
    ) as! [String: Any]
    systemTransitionRoot["SystemTransitionSentinel"] = "must-survive"
    let systemTransitionData = try PropertyListSerialization.data(
        fromPropertyList: systemTransitionRoot,
        format: .binary,
        options: 0
    )
    fixture.installer.sharedDesktopImageRestoreHook = { path in
        guard URL(fileURLWithPath: path).standardizedFileURL ==
                targetURL.standardizedFileURL
        else {
            return false
        }
        try? systemTransitionData.write(
            to: fixture.storeURL,
            options: .atomic
        )
        return true
    }

    try fixture.installer.uninstall()

    let providerLaunchData = try #require(refreshSnapshots.last)
    let providerLaunchRoot = try #require(
        PropertyListSerialization.propertyList(
            from: providerLaunchData,
            options: [],
            format: nil
        ) as? [String: Any]
    )
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        let container = try #require(
            providerLaunchRoot[key] as? [String: Any]
        )
        let desktop = try #require(container["Desktop"] as? [String: Any])
        let content = try #require(desktop["Content"] as? [String: Any])
        let choice = try #require(
            (content["Choices"] as? [[String: Any]])?.first
        )
        let files = try #require(choice["Files"] as? [[String: Any]])
        #expect(files.first?["relative"] as? String == targetURL.absoluteString)
    }
    #expect(try Data(contentsOf: fixture.storeURL) == systemTransitionData)
    #expect(!fixture.installer.isInstalled)
}

@Test func sharedRemoveCleansRecoveryOnlyAfterImageTransitionSucceeds() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }
    try await fixture.installer.install(videoURL: fixture.videoURL)
    let targetURL = fixture.root.appendingPathComponent("selected-user.png")
    try Data("selected-user".utf8).write(to: targetURL)
    var root = try readWallpaperStore(fixture.storeURL)
    let mode = try testImageWallpaperMode(url: targetURL, timestamp: Date())
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        var container = try #require(root[key] as? [String: Any])
        container["Desktop"] = mode
        root[key] = container
    }
    try writeWallpaperStore(root, to: fixture.storeURL)
    var refreshCountAtTransition = -1
    var restoredPath: String?
    var storeAtTransition: Data?
    fixture.installer.sharedDesktopImageRestoreHook = { path in
        restoredPath = path
        refreshCountAtTransition = fixture.refreshCounter.count
        storeAtTransition = try? Data(contentsOf: fixture.storeURL)
        return true
    }

    try fixture.installer.uninstall()

    #expect(restoredPath == targetURL.standardizedFileURL.path)
    #expect(
        storeAtTransition.map(wallpaperStoreText)?.contains(
            targetURL.absoluteString
        ) == true
    )
    #expect(fixture.refreshCounter.count == refreshCountAtTransition)
    #expect(
        wallpaperStoreText(try readWallpaperStore(fixture.storeURL))
            .contains(targetURL.absoluteString)
    )
    #expect(!FileManager.default.fileExists(
        atPath: fixture.stateURL
            .appendingPathComponent("installation.json").path
    ))
    #expect(!fixture.installer.isInstalled)
}

@Test func unconfirmedSharedImageTransitionDoesNotRestartAura() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }
    try await fixture.installer.install(videoURL: fixture.videoURL)
    let targetURL = fixture.root.appendingPathComponent("selected-user.jpg")
    try Data("selected-user".utf8).write(to: targetURL)
    var root = try readWallpaperStore(fixture.storeURL)
    let mode = try testImageWallpaperMode(url: targetURL, timestamp: Date())
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        var container = try #require(root[key] as? [String: Any])
        container["Desktop"] = mode
        root[key] = container
    }
    try writeWallpaperStore(root, to: fixture.storeURL)
    var refreshCountAtTransition = -1
    fixture.installer.sharedDesktopImageRestoreHook = { _ in
        refreshCountAtTransition = fixture.refreshCounter.count
        return false
    }

    try fixture.installer.uninstall()

    #expect(fixture.refreshCounter.count == refreshCountAtTransition)
    #expect(!FileManager.default.fileExists(
        atPath: fixture.stateURL
            .appendingPathComponent("installation.json").path
    ))
    #expect(!fixture.installer.isInstalled)
    #expect(
        wallpaperStoreText(try readWallpaperStore(fixture.storeURL))
            .contains(targetURL.absoluteString)
    )
}

@Test func imageTransitionIsNeverUsedForLockOnlyOrNativeDesktopProvider() async throws {
    let lockFixture = try AerialLockScreenFixture()
    defer { lockFixture.cleanup() }
    var lockOnlyTransitionCount = 0
    lockFixture.installer.sharedDesktopImageRestoreHook = { _ in
        lockOnlyTransitionCount += 1
        return true
    }
    try await lockFixture.installer.installLockScreenOnly(
        videoURL: lockFixture.videoURL
    )
    try lockFixture.installer.uninstallLockScreenOnlyPreservingCurrentDesktop()
    #expect(lockOnlyTransitionCount == 0)

    let sharedFixture = try AerialLockScreenFixture()
    defer { sharedFixture.cleanup() }
    try await sharedFixture.installer.install(videoURL: sharedFixture.videoURL)
    var root = try readWallpaperStore(sharedFixture.storeURL)
    let nativeMode = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.sequoia",
        configuration: [:]
    )
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        var container = try #require(root[key] as? [String: Any])
        container["Desktop"] = nativeMode
        root[key] = container
    }
    try writeWallpaperStore(root, to: sharedFixture.storeURL)
    var nativeTransitionCount = 0
    sharedFixture.installer.sharedDesktopImageRestoreHook = { _ in
        nativeTransitionCount += 1
        return true
    }
    try sharedFixture.installer.uninstall()
    #expect(nativeTransitionCount == 0)
}

@Test func lateManagedSnapshotDoesNotOverwriteLatestUserJournal() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }
    let fallbackData = try Data(contentsOf: fixture.storeURL)
    let customURL = fixture.root.appendingPathComponent("latest-user.jpg")
    try Data("latest-user".utf8).write(to: customURL)
    var customRoot = try readWallpaperStore(fixture.storeURL)
    let customMode = try testImageWallpaperMode(
        url: customURL,
        timestamp: Date(timeIntervalSince1970: 2_000)
    )
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        var container = try #require(customRoot[key] as? [String: Any])
        container["Desktop"] = customMode
        customRoot[key] = container
    }
    let customData = try PropertyListSerialization.data(
        fromPropertyList: customRoot,
        format: .binary,
        options: 0
    )
    let transactionWithoutJournal = WallpaperStoreTransaction(
        fileManager: .default,
        wallpaperStoreURL: fixture.storeURL,
        spacesPreferencesURL: fixture.spacesURL,
        aerialVideosURL: fixture.videosURL
    )
    let managedData = try transactionWithoutJournal
        .aerialWallpaperStoreData(
            from: fallbackData,
            assetID: AerialLockScreenFixture.assetID,
            scope: .sharedWallpaper
        )
    let journalURL = fixture.stateURL
        .appendingPathComponent("Index.latest-user.plist")
    let transaction = WallpaperStoreTransaction(
        fileManager: .default,
        wallpaperStoreURL: fixture.storeURL,
        spacesPreferencesURL: fixture.spacesURL,
        aerialVideosURL: fixture.videosURL,
        latestUserWallpaperStoreURL: journalURL
    )

    _ = try transaction.captureLatestUserWallpaperStoreData(
        from: customData,
        fallbackData: fallbackData,
        managedAssetID: AerialLockScreenFixture.assetID,
        propagateGlobalDesktopChanges: true
    )
    _ = try transaction.captureLatestUserWallpaperStoreData(
        from: managedData,
        fallbackData: fallbackData,
        managedAssetID: AerialLockScreenFixture.assetID,
        propagateGlobalDesktopChanges: true
    )

    let journalData = try Data(contentsOf: journalURL)
    #expect(wallpaperStoreText(
        try PropertyListSerialization.propertyList(
            from: journalData,
            options: [],
            format: nil
        )
    ).contains(customURL.absoluteString))
}

@Test func concurrentJournalCallbacksAlwaysLeaveAValidUserSnapshot() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }
    let fallbackData = try Data(contentsOf: fixture.storeURL)
    let journalURL = fixture.stateURL
        .appendingPathComponent("Index.latest-user.plist")
    let firstURL = fixture.root.appendingPathComponent("first-user.jpg")
    let secondURL = fixture.root.appendingPathComponent("second-user.jpg")
    try Data("first".utf8).write(to: firstURL)
    try Data("second".utf8).write(to: secondURL)
    let userStores = try [firstURL, secondURL].map { url in
        try testImageWallpaperStoreData(url: url, timestamp: Date())
    }
    let failures = ConcurrentFailureCounter()

    DispatchQueue.concurrentPerform(iterations: 40) { index in
        let transaction = WallpaperStoreTransaction(
            fileManager: .default,
            wallpaperStoreURL: fixture.storeURL,
            spacesPreferencesURL: fixture.spacesURL,
            aerialVideosURL: fixture.videosURL,
            latestUserWallpaperStoreURL: journalURL
        )
        do {
            _ = try transaction.captureLatestUserWallpaperStoreData(
                from: userStores[index % userStores.count],
                fallbackData: fallbackData,
                managedAssetID: AerialLockScreenFixture.assetID,
                propagateGlobalDesktopChanges: true
            )
        } catch {
            failures.record()
        }
    }

    #expect(failures.value == 0)
    let journalRoot = try #require(
        PropertyListSerialization.propertyList(
            from: Data(contentsOf: journalURL),
            options: [],
            format: nil
        ) as? [String: Any]
    )
    let journalText = wallpaperStoreText(journalRoot)
    #expect(
        journalText.contains(firstURL.absoluteString)
            || journalText.contains(secondURL.absoluteString)
    )
}

@Test func sharedRemoveFallsBackFromStaleDefaultJournalToOriginalDesktop() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.install(videoURL: fixture.videoURL)
    let currentData = try Data(contentsOf: fixture.storeURL)
    let fallbackData = try Data(contentsOf: fixture.stateURL
        .appendingPathComponent("Index.before-auraflow.plist"))
    let staleDefault = AerialLockScreenFixture.makeMode(
        provider: "default",
        configuration: [:]
    )
    let staleContainer: [String: Any] = [
        "Type": "individual",
        "Desktop": staleDefault,
    ]
    let staleRoot: [String: Any] = [
        "AllSpacesAndDisplays": staleContainer,
        "SystemDefault": staleContainer,
    ]
    let staleData = try PropertyListSerialization.data(
        fromPropertyList: staleRoot,
        format: .binary,
        options: 0
    )
    let latestUserStoreURL = fixture.stateURL
        .appendingPathComponent("Index.latest-user.plist")
    try staleData.write(to: latestUserStoreURL, options: .atomic)

    let transaction = WallpaperStoreTransaction(
        fileManager: .default,
        wallpaperStoreURL: fixture.storeURL,
        spacesPreferencesURL: fixture.spacesURL,
        aerialVideosURL: fixture.videosURL,
        latestUserWallpaperStoreURL: latestUserStoreURL
    )
    let restoredData = try transaction.captureLatestUserWallpaperStoreData(
        from: currentData,
        fallbackData: fallbackData,
        managedAssetID: AerialLockScreenFixture.assetID,
        propagateGlobalDesktopChanges: true
    )
    let restoredRoot = try #require(
        try transaction.propertyListDictionary(from: restoredData)
    )
    let restoredContainer = try #require(
        restoredRoot["SystemDefault"] as? [String: Any]
    )
    let restoredDesktop = try #require(
        restoredContainer["Desktop"] as? [String: Any]
    )

    #expect(wallpaperStoreText(restoredDesktop).contains("original.jpg"))
    #expect(!wallpaperStoreText(restoredDesktop).contains("default"))
}

@Test func modernLockScreenUsesAerialAndPrunesDeletedSpaces() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.install(videoURL: fixture.videoURL)

    #expect(fixture.installer.isInstalled)
    #expect(fixture.installer.installationConfirmed)
    #expect(
        try Data(contentsOf: fixture.assetURL)
            == Data("new-wallpaper".utf8)
    )
    let root = try readWallpaperStore(fixture.storeURL)
    let allSpacesAndDisplays = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    #expect(
        wallpaperStoreContains(
            allSpacesAndDisplays,
            provider: "com.apple.wallpaper.choice.aerials",
            assetID: AerialLockScreenFixture.assetID
        )
    )
    let spaces = try #require(root["Spaces"] as? [String: Any])
    #expect(Set(spaces.keys) == [AerialLockScreenFixture.activeSpaceID])
    let displays = try #require(root["Displays"] as? [String: Any])
    #expect(Set(displays.keys) == [AerialLockScreenFixture.displayID])
    let activeSpace = try #require(
        spaces[AerialLockScreenFixture.activeSpaceID] as? [String: Any]
    )
    let activeDisplays = try #require(
        activeSpace["Displays"] as? [String: Any]
    )
    #expect(
        Set(activeDisplays.keys)
            == [AerialLockScreenFixture.displayID]
    )
    #expect(
        wallpaperStoreContains(
            root,
            provider: "com.apple.wallpaper.choice.aerials",
            assetID: AerialLockScreenFixture.assetID
        )
    )
    #expect(!wallpaperStoreText(root).contains("last_frame"))
    #expect(!wallpaperStoreText(root).contains("AuraFlowLockScreen"))
}

@Test func modernSharedInstallAcceptsIdleOnlyAggregateContainer() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    var root = try readWallpaperStore(fixture.storeURL)
    var aggregate = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    // macOS 26 can keep the aggregate route as Idle-only while the concrete
    // Space/Display containers own the Desktop route.
    aggregate.removeValue(forKey: "Desktop")
    aggregate.removeValue(forKey: "Linked")
    aggregate["Type"] = "idle"
    root["AllSpacesAndDisplays"] = aggregate
    try writeWallpaperStore(root, to: fixture.storeURL)

    try await fixture.installer.install(videoURL: fixture.videoURL)

    #expect(fixture.installer.installationConfirmed)
    let installedRoot = try readWallpaperStore(fixture.storeURL)
    let installedAggregate = try #require(
        installedRoot["AllSpacesAndDisplays"] as? [String: Any]
    )
    let installedIdle = try #require(
        installedAggregate["Idle"] as? [String: Any]
    )
    #expect(wallpaperStoreContains(
        installedIdle,
        provider: "com.apple.wallpaper.choice.aerials",
        assetID: AerialLockScreenFixture.assetID
    ))
}

@Test func modernSharedLockScreenPlaybackPauseAndResumeRestoresAerialAsset() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    let videoURL = fixture.root.appendingPathComponent("shared-wallpaper.mp4")
    try await writeAerialTestVideo(to: videoURL)
    try await fixture.installer.install(videoURL: videoURL)
    let runningAsset = try Data(contentsOf: fixture.assetURL)

    #expect(!fixture.installer.isLockScreenOnlyInstallation)
    #expect(
        try await fixture.installer.pauseLockScreenOnlyPlayback(
            videoURL: videoURL
        )
    )
    let pausedAsset = try Data(contentsOf: fixture.assetURL)
    #expect(pausedAsset != runningAsset)

    #expect(
        try await fixture.installer.resumeLockScreenOnlyPlayback(
            videoURL: videoURL
        )
    )
    #expect(try Data(contentsOf: fixture.assetURL) == runningAsset)
    #expect(fixture.rearmCounter.rearmCount == 3)
}

@Test func pausedDesktopAgentRouteStaysFrozenAcrossRepeatedLockRearms() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    let videoURL = fixture.root.appendingPathComponent(
        "paused-desktop-agent-wallpaper.mp4"
    )
    try await writeAerialTestVideo(to: videoURL)
    try await fixture.installer.installForDesktopAgent(videoURL: videoURL)
    let runningAsset = try Data(contentsOf: fixture.assetURL)

    #expect(
        try await fixture.installer.pauseLockScreenOnlyPlayback(
            videoURL: videoURL
        )
    )
    let pausedAsset = try Data(contentsOf: fixture.assetURL)
    let refreshCountAfterPause = fixture.rearmCounter.rearmCount
    #expect(pausedAsset != runningAsset)

    for _ in 0..<3 {
        #expect(
            try await fixture.installer.rearmForNextLock(videoURL: videoURL)
                == false
        )
        #expect(try Data(contentsOf: fixture.assetURL) == pausedAsset)
        #expect(fixture.rearmCounter.rearmCount == refreshCountAfterPause)
        #expect(
            LockScreenJournal(
                stateDirectoryURL: fixture.stateURL,
                fileManager: .default
            ).loadMarker()?.state == "paused"
        )
    }

    #expect(
        try await fixture.installer.resumeLockScreenOnlyPlayback(
            videoURL: videoURL
        )
    )
    #expect(try Data(contentsOf: fixture.assetURL) == runningAsset)
}

@Test func modernLockScreenPlaybackSpeedIsPersistedPerGeneration() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.install(videoURL: fixture.videoURL)

    #expect(
        try await fixture.installer.updatePlaybackSpeed(
            videoURL: fixture.videoURL,
            speed: 1.75
        )
    )
    let marker = LockScreenJournal(
        stateDirectoryURL: fixture.stateURL,
        fileManager: .default
    ).loadMarker()
    #expect(marker?.playbackSpeed == 1.75)
    #expect(
        try await fixture.installer.updatePlaybackSpeed(
            videoURL: fixture.videoURL,
            speed: 1.75
    ) == false
    )
}

@Test func modernLockScreenScaleModeIsPersistedPerGeneration() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.install(videoURL: fixture.videoURL)

    #expect(
        try await fixture.installer.updateScaleMode(
            videoURL: fixture.videoURL,
            mode: .fit
        )
    )
    let marker = LockScreenJournal(
        stateDirectoryURL: fixture.stateURL,
        fileManager: .default
    ).loadMarker()
    #expect(marker?.scaleMode == WallpaperScaleMode.fit.rawValue)
    #expect(
        try await fixture.installer.rearmForNextLock(
            videoURL: fixture.videoURL
        )
    )
    #expect(
        LockScreenJournal(
            stateDirectoryURL: fixture.stateURL,
            fileManager: .default
        ).loadMarker()?.scaleMode == WallpaperScaleMode.fit.rawValue
    )
    #expect(
        try await fixture.installer.updateScaleMode(
            videoURL: fixture.videoURL,
            mode: .fit
        ) == false
    )
}

@Test func modernLockScreenOnlyPlaybackSpeedUsesLockOnlyGeneration() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    #expect(
        try await fixture.installer.updatePlaybackSpeed(
            videoURL: fixture.videoURL,
            speed: 0.5
        )
    )
    let marker = LockScreenJournal(
        stateDirectoryURL: fixture.stateURL,
        fileManager: .default
    ).loadMarker()
    #expect(marker?.lockScreenOnly == true)
    #expect(marker?.playbackSpeed == 0.5)
}

@Test func modernLockScreenOnlyPlaybackPauseAndResumeRestoresAerialAsset() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    let videoURL = fixture.root.appendingPathComponent("lock-only-wallpaper.mp4")
    try await writeAerialTestVideo(to: videoURL)
    try await fixture.installer.installLockScreenOnly(videoURL: videoURL)
    let runningAsset = try Data(contentsOf: fixture.assetURL)

    #expect(fixture.installer.isLockScreenOnlyInstallation)
    #expect(
        try await fixture.installer.pauseLockScreenOnlyPlayback(
            videoURL: videoURL
        )
    )
    #expect(try Data(contentsOf: fixture.assetURL) != runningAsset)
    #expect(
        try await fixture.installer.resumeLockScreenOnlyPlayback(
            videoURL: videoURL
        )
    )
    #expect(try Data(contentsOf: fixture.assetURL) == runningAsset)

    // A second Stop -> Play must remain a normal toggle, not trip the
    // one-time protection intended for an externally replaced asset.
    #expect(
        try await fixture.installer.pauseLockScreenOnlyPlayback(
            videoURL: videoURL
        )
    )
    #expect(
        try await fixture.installer.resumeLockScreenOnlyPlayback(
            videoURL: videoURL
        )
    )
    #expect(try Data(contentsOf: fixture.assetURL) == runningAsset)
}

@Test func modernLockScreenConfirmationRejectsAStaleWallpaperStore() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    let originalStore = try Data(contentsOf: fixture.storeURL)
    try await fixture.installer.install(videoURL: fixture.videoURL)
    #expect(fixture.installer.installationConfirmed)

    try originalStore.write(to: fixture.storeURL, options: .atomic)
    #expect(!fixture.installer.installationConfirmed)
}

@Test func modernLockScreenRecoversFromOneStaleWallpaperAgentFlush() async throws {
    var staleStoreData: Data?
    let fixture = try AerialLockScreenFixture(onRefresh: { storeURL in
        try? staleStoreData?.write(to: storeURL, options: .atomic)
    })
    defer { fixture.cleanup() }
    staleStoreData = try Data(contentsOf: fixture.storeURL)

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    #expect(fixture.installer.installationConfirmed)
    #expect(fixture.refreshCounter.count == 1)
    let root = try readWallpaperStore(fixture.storeURL)
    #expect(wallpaperStoreContains(
        root,
        provider: "com.apple.wallpaper.choice.aerials",
        assetID: AerialLockScreenFixture.assetID
    ))
}

@Test func modernLockScreenOnlyRearmsProviderForNewGeneration() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    #expect(fixture.rearmCounter.rearmCount == 1)
    #expect(fixture.lockSessionHandoffCounter.lockSessionHandoffCount == 0)
    #expect(fixture.installer.installationConfirmed)
}

@Test func explicitLockApplyRearmsAnAlreadyCurrentProvider() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    #expect(fixture.rearmCounter.rearmCount == 2)
    #expect(fixture.installer.installationConfirmed)
}

@Test func modernLockScreenOnlyPreservesDesktopRoute() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    let root = try readWallpaperStore(fixture.storeURL)
    let allSpacesAndDisplays = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    let desktop = try #require(
        allSpacesAndDisplays["Desktop"] as? [String: Any]
    )
    let idle = try #require(
        allSpacesAndDisplays["Idle"] as? [String: Any]
    )

    #expect(wallpaperStoreContains(
        desktop,
        provider: "com.apple.wallpaper.choice.image",
        assetID: nil
    ))
    #expect(
        wallpaperStoreContains(
            idle,
            provider: "com.apple.wallpaper.choice.aerials",
            assetID: AerialLockScreenFixture.assetID
        )
    )
    #expect(fixture.installer.installationConfirmed)
    #expect(fixture.refreshCounter.count == 1)
}

@Test func desktopAgentNativeInstallNeverReplacesDesktopOrLinkedRoutes() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    var root = try readWallpaperStore(fixture.storeURL)
    root = replaceTestDesktopModesDistinctly(in: root)
    try writeWallpaperStore(root, to: fixture.storeURL)
    let expectedDesktopRoutes = testDesktopRouteData(in: root)
    #expect(expectedDesktopRoutes.count > 2)

    try await fixture.installer.installForDesktopAgent(
        videoURL: fixture.videoURL
    )

    root = try readWallpaperStore(fixture.storeURL)
    #expect(testDesktopRouteData(in: root) == expectedDesktopRoutes)
    for container in testWallpaperContainers(in: root) {
        if let desktop = container["Desktop"] as? [String: Any] {
            #expect(!wallpaperStoreContains(
                desktop,
                provider: "com.apple.wallpaper.choice.aerials",
                assetID: AerialLockScreenFixture.assetID
            ))
        }
        if let linked = container["Linked"] as? [String: Any] {
            #expect(!wallpaperStoreContains(
                linked,
                provider: "com.apple.wallpaper.choice.aerials",
                assetID: AerialLockScreenFixture.assetID
            ))
        }
        if let idle = container["Idle"] as? [String: Any] {
            #expect(wallpaperStoreContains(
                idle,
                provider: "com.apple.wallpaper.choice.aerials",
                assetID: AerialLockScreenFixture.assetID
            ))
        }
    }
    #expect(!fixture.installer.isLockScreenOnlyInstallation)
    #expect(fixture.installer.requiresLockScreenSessionPromotion)
    #expect(fixture.installer.installationConfirmed)
}

@Test func desktopAgentNativeRemovePreservesEveryDesktopWithoutImageTransition() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    var root = try readWallpaperStore(fixture.storeURL)
    root = replaceTestDesktopModesDistinctly(in: root)
    try writeWallpaperStore(root, to: fixture.storeURL)
    let expectedDesktopRoutes = testDesktopRouteData(in: root)
    var imageTransitionCalls = 0
    fixture.installer.sharedDesktopImageRestoreHook = { _ in
        imageTransitionCalls += 1
        return false
    }

    try await fixture.installer.installForDesktopAgent(
        videoURL: fixture.videoURL
    )
    let refreshCountBeforeRemove = fixture.refreshCounter.count
    try fixture.installer
        .uninstallLockScreenOnlyPreservingCurrentDesktop()

    root = try readWallpaperStore(fixture.storeURL)
    #expect(testDesktopRouteData(in: root) == expectedDesktopRoutes)
    #expect(imageTransitionCalls == 0)
    #expect(fixture.refreshCounter.count == refreshCountBeforeRemove)
    #expect(!fixture.installer.isInstalled)
}

@Test func desktopAgentNativeRoutePromotesOnlyForLockSession() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    var root = try readWallpaperStore(fixture.storeURL)
    root = replaceTestDesktopModesDistinctly(in: root)
    try writeWallpaperStore(root, to: fixture.storeURL)
    let expectedDesktopRoutes = testDesktopRouteData(in: root)
    try await fixture.installer.installForDesktopAgent(
        videoURL: fixture.videoURL
    )

    _ = try fixture.installer.activateLockScreenForCurrentSession()
    root = try readWallpaperStore(fixture.storeURL)
    #expect(testWallpaperContainers(in: root).contains { container in
        guard let desktop = container["Desktop"] as? [String: Any] else {
            return false
        }
        return wallpaperStoreContains(
            desktop,
            provider: "com.apple.wallpaper.choice.aerials",
            assetID: AerialLockScreenFixture.assetID
        )
    })

    _ = try fixture.installer.restoreDesktopAfterLockScreenSession()
    root = try readWallpaperStore(fixture.storeURL)
    #expect(testDesktopRouteData(in: root) == expectedDesktopRoutes)
    #expect(fixture.installer.installationConfirmed)
}

@Test func desktopAgentNativeSourceChangeKeepsLatestDesktopRoutes() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installForDesktopAgent(
        videoURL: fixture.videoURL
    )
    var root = try readWallpaperStore(fixture.storeURL)
    root = replaceTestDesktopModesDistinctly(in: root)
    try writeWallpaperStore(root, to: fixture.storeURL)
    let expectedDesktopRoutes = testDesktopRouteData(in: root)

    let secondVideoURL = fixture.root.appendingPathComponent("wallpaper-b.mp4")
    try Data("second-wallpaper".utf8).write(to: secondVideoURL)
    try await fixture.installer.installForDesktopAgent(
        videoURL: secondVideoURL
    )

    root = try readWallpaperStore(fixture.storeURL)
    #expect(testDesktopRouteData(in: root) == expectedDesktopRoutes)
    #expect(fixture.installer.requiresLockScreenSessionPromotion)
    #expect(fixture.installer.installationConfirmed)
}

@Test func desktopAgentNativeMigratesOldSharedStartFromLatestUserJournal() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.install(videoURL: fixture.videoURL)
    let managedSharedStore = try Data(contentsOf: fixture.storeURL)
    var latestUserRoot = try readWallpaperStore(fixture.storeURL)
    latestUserRoot = replaceTestDesktopModesDistinctly(in: latestUserRoot)
    let latestUserData = try PropertyListSerialization.data(
        fromPropertyList: latestUserRoot,
        format: .binary,
        options: 0
    )
    let expectedDesktopRoutes = testDesktopRouteData(in: latestUserRoot)
    try latestUserData.write(
        to: fixture.stateURL.appendingPathComponent("Index.latest-user.plist"),
        options: .atomic
    )
    // Reproduce the stale flush that caused Golden Gate: the system owner
    // writes the old shared Aerial route after the user journal was captured.
    try managedSharedStore.write(to: fixture.storeURL, options: .atomic)

    try await fixture.installer.installForDesktopAgent(
        videoURL: fixture.videoURL
    )

    let migratedRoot = try readWallpaperStore(fixture.storeURL)
    #expect(testDesktopRouteData(in: migratedRoot) == expectedDesktopRoutes)
    #expect(!fixture.installer.isLockScreenOnlyInstallation)
    #expect(fixture.installer.requiresLockScreenSessionPromotion)
    #expect(fixture.installer.installationConfirmed)
}

@Test func lockOnlyApplyKeepsLatestDesktopWhenSourceChanges() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    var root = try readWallpaperStore(fixture.storeURL)
    root = replaceTestDesktopModes(
        in: root,
        provider: "com.apple.wallpaper.choice.user-latest"
    )
    try writeWallpaperStore(root, to: fixture.storeURL)
    let latestDesktopRoutes = testDesktopRouteData(in: root)

    let secondVideoURL = fixture.root.appendingPathComponent("wallpaper-b.mp4")
    try Data("second-wallpaper".utf8).write(to: secondVideoURL)
    try await fixture.installer.installLockScreenOnly(videoURL: secondVideoURL)

    root = try readWallpaperStore(fixture.storeURL)
    #expect(testDesktopRouteData(in: root) == latestDesktopRoutes)
    // Replacing an already-installed Lock-only source keeps WallpaperAgent
    // alive; the updated Idle route is consumed by the next lock transition.
    #expect(fixture.refreshCounter.count == 1)
}

@Test func lockOnlyRepairRefreshesStaleAssetSignature() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    let markerURL = fixture.stateURL
        .appendingPathComponent("installation.json")
    var marker = try #require(
        JSONSerialization.jsonObject(
            with: Data(contentsOf: markerURL)
        ) as? [String: Any]
    )
    marker["assetSignature"] = "stale-asset-signature"
    try JSONSerialization.data(
        withJSONObject: marker,
        options: [.prettyPrinted, .sortedKeys]
    ).write(to: markerURL, options: .atomic)

    #expect(
        !fixture.installer.lockScreenOnlyStatus(
            videoURL: fixture.videoURL
        ).assetValid
    )

    _ = try await fixture.installer.repairLockScreenOnlyGeneration(
        videoURL: fixture.videoURL
    )

    let repairedMarker = try #require(
        JSONSerialization.jsonObject(
            with: Data(contentsOf: markerURL)
        ) as? [String: Any]
    )
    #expect(repairedMarker["assetSignature"] as? String != "stale-asset-signature")
    #expect(
        fixture.installer.lockScreenOnlyStatus(
            videoURL: fixture.videoURL
        ).assetValid
    )
}

@Test func lockOnlyStatusRejectsAssetWithStaleJournalAndNoOwnershipStamp() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    let removeResult = fixture.assetURL.path.withCString { path in
        AerialAssetStore.managedAssetSignatureAttribute.withCString {
            removexattr(path, $0, 0)
        }
    }
    #expect(removeResult == 0)

    let status = fixture.installer.lockScreenOnlyStatus(
        videoURL: fixture.videoURL
    )
    #expect(status.sourceMatches)
    #expect(status.assetValid == false)
}

@Test func lockOnlyApplyReplacesAnUnstampedAssetEvenWhenJournalMatches() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    let removeResult = fixture.assetURL.path.withCString { path in
        AerialAssetStore.managedAssetSignatureAttribute.withCString {
            removexattr(path, $0, 0)
        }
    }
    #expect(removeResult == 0)
    #expect(
        fixture.installer.lockScreenOnlyStatus(
            videoURL: fixture.videoURL
        ).assetValid == false
    )

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    #expect(
        fixture.installer.lockScreenOnlyStatus(
            videoURL: fixture.videoURL
        ).assetValid
    )
    #expect(
        AerialAssetStore(
            aerialVideosURL: fixture.videosURL,
            aerialThumbnailsURL: fixture.thumbnailsURL,
            aerialProviderURL: fixture.providerURL,
            fileManager: .default
        ).managedAssetSignature(at: fixture.assetURL) != nil
    )
}

@Test func repeatedExternalAssetOverwriteStopsRepairLoop() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    try Data("first-system-overwrite".utf8).write(
        to: fixture.assetURL,
        options: .atomic
    )
    _ = try await fixture.installer.repairLockScreenOnlyGeneration(
        videoURL: fixture.videoURL
    )
    try Data("second-system-overwrite".utf8).write(
        to: fixture.assetURL,
        options: .atomic
    )

    await expectAsyncThrowing(AerialLockScreenInstallerError.self) {
        _ = try await fixture.installer.repairLockScreenOnlyGeneration(
            videoURL: fixture.videoURL
        )
    }
    #expect(
        try Data(contentsOf: fixture.assetURL)
            == Data("second-system-overwrite".utf8)
    )
}

@Test func lockOnlyRepairRestoresDriftedIdleWithoutChangingDesktopRoutes() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    var root = try readWallpaperStore(fixture.storeURL)
    let desktopBefore = testDesktopRouteData(in: root)

    // Simulate macOS replacing one Idle route with its own wallpaper after a
    // few lock/unlock cycles. The user Desktop remains the live source.
    var allSpaces = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    allSpaces["Idle"] = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.aerials",
        configuration: ["assetID": AerialLockScreenFixture.alternateAssetID]
    )
    root["AllSpacesAndDisplays"] = allSpaces
    try writeWallpaperStore(root, to: fixture.storeURL)

    let drifted = fixture.installer.lockScreenOnlyStatus(
        videoURL: fixture.videoURL
    )
    #expect(!drifted.wallpaperStoreValid)

    _ = try await fixture.installer.repairLockScreenOnlyGeneration(
        videoURL: fixture.videoURL
    )

    root = try readWallpaperStore(fixture.storeURL)
    #expect(testDesktopRouteData(in: root) == desktopBefore)
    #expect(
        fixture.installer.lockScreenOnlyStatus(
            videoURL: fixture.videoURL
        ).wallpaperStoreValid
    )
    // The fixture uses a non-canonical provider, so repairing only Idle does
    // not restart a real WallpaperAgent.
    #expect(fixture.refreshCounter.count == 1)
}

@Test func lockOnlyRepairDoesNotOverwriteDesktopChangedDuringRepair() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    var root = try readWallpaperStore(fixture.storeURL)
    var allSpaces = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    allSpaces["Idle"] = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.aerials",
        configuration: ["assetID": AerialLockScreenFixture.alternateAssetID]
    )
    root["AllSpacesAndDisplays"] = allSpaces
    try writeWallpaperStore(root, to: fixture.storeURL)

    let latestDesktop = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.sequoia",
        configuration: ["revision": 2]
    )
    root = try readWallpaperStore(fixture.storeURL)
    allSpaces = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    allSpaces["Desktop"] = latestDesktop
    root["AllSpacesAndDisplays"] = allSpaces
    let latestRoot = root
    fixture.installer.lockOnlyRepairCommitHook = {
        try? writeWallpaperStore(latestRoot, to: fixture.storeURL)
    }

    _ = try await fixture.installer.repairLockScreenOnlyGeneration(
        videoURL: fixture.videoURL
    )
    root = try readWallpaperStore(fixture.storeURL)
    allSpaces = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    let desktopAfter = try #require(
        allSpaces["Desktop"] as? [String: Any]
    )
    #expect(wallpaperModeData(desktopAfter) == wallpaperModeData(latestDesktop))
    #expect(
        fixture.installer.lockScreenOnlyStatus(
            videoURL: fixture.videoURL
        ).wallpaperStoreValid == false
    )
}

@Test func linkedWallpaperPromotesOnlyDuringLockSession() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    let userLinkedMode = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.sequoia",
        configuration: [:]
    )
    var linkedRoot = try readWallpaperStore(fixture.storeURL)
    let linkedContainer: [String: Any] = [
        "Type": "linked",
        "Linked": userLinkedMode,
    ]
    linkedRoot["AllSpacesAndDisplays"] = linkedContainer
    linkedRoot["SystemDefault"] = linkedContainer
    linkedRoot["Displays"] = [String: Any]()
    linkedRoot["Spaces"] = [String: Any]()
    try writeWallpaperStore(linkedRoot, to: fixture.storeURL)

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    var root = try readWallpaperStore(fixture.storeURL)
    var container = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    var desktop = try #require(container["Desktop"] as? [String: Any])
    #expect(wallpaperStoreContains(
        desktop,
        provider: "com.apple.wallpaper.choice.sequoia",
        assetID: nil
    ))
    let idle = try #require(container["Idle"] as? [String: Any])
    #expect(wallpaperStoreContains(
        idle,
        provider: "com.apple.wallpaper.choice.aerials",
        assetID: AerialLockScreenFixture.assetID
    ))

    let promoted = try fixture.installer
        .activateLockScreenForCurrentSession()
    #expect(promoted)
    root = try readWallpaperStore(fixture.storeURL)
    container = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    let lockLinked = try #require(container["Linked"] as? [String: Any])
    #expect(wallpaperStoreContains(
        lockLinked,
        provider: "com.apple.wallpaper.choice.aerials",
        assetID: AerialLockScreenFixture.assetID
    ))
    #expect(container["Type"] as? String == "linked")

    _ = try fixture.installer.restoreDesktopAfterLockScreenSession()
    root = try readWallpaperStore(fixture.storeURL)
    container = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    desktop = try #require(container["Desktop"] as? [String: Any])
    #expect(wallpaperStoreContains(
        desktop,
        provider: "com.apple.wallpaper.choice.sequoia",
        assetID: nil
    ))
}

@Test func linkedWallpaperChangedByUserSurvivesLockOnlyRemove() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    var root = try readWallpaperStore(fixture.storeURL)
    let originalContainer: [String: Any] = [
        "Type": "linked",
        "Linked": AerialLockScreenFixture.makeMode(
            provider: "com.apple.wallpaper.choice.sequoia",
            configuration: [:]
        ),
    ]
    root["AllSpacesAndDisplays"] = originalContainer
    root["SystemDefault"] = originalContainer
    root["Displays"] = [String: Any]()
    root["Spaces"] = [String: Any]()
    try writeWallpaperStore(root, to: fixture.storeURL)
    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    let latestContainer: [String: Any] = [
        "Type": "linked",
        "Linked": AerialLockScreenFixture.makeMode(
            provider: "com.apple.wallpaper.choice.sonoma",
            configuration: [:]
        ),
    ]
    root = try readWallpaperStore(fixture.storeURL)
    root["AllSpacesAndDisplays"] = latestContainer
    root["SystemDefault"] = latestContainer
    try writeWallpaperStore(root, to: fixture.storeURL)

    try fixture.installer.uninstall()

    root = try readWallpaperStore(fixture.storeURL)
    let restoredContainer = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    let restoredLinked = try #require(
        restoredContainer["Linked"] as? [String: Any]
    )
    #expect(wallpaperStoreContains(
        restoredLinked,
        provider: "com.apple.wallpaper.choice.sonoma",
        assetID: nil
    ))
}

@Test func linkedWallpaperRemoveUsesCurrentDesktopNotOlderJournal() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    var root = try readWallpaperStore(fixture.storeURL)
    let originalContainer: [String: Any] = [
        "Type": "linked",
        "Linked": AerialLockScreenFixture.makeMode(
            provider: "com.apple.wallpaper.choice.sequoia",
            configuration: [:]
        ),
    ]
    root["AllSpacesAndDisplays"] = originalContainer
    root["SystemDefault"] = originalContainer
    root["Displays"] = [String: Any]()
    root["Spaces"] = [String: Any]()
    try writeWallpaperStore(root, to: fixture.storeURL)
    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    root = try readWallpaperStore(fixture.storeURL)
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        var split = try #require(root[key] as? [String: Any])
        var latestDesktop = AerialLockScreenFixture.makeMode(
            provider: "com.apple.wallpaper.choice.sonoma",
            configuration: [:]
        )
        latestDesktop["LastSet"] = Date().addingTimeInterval(60)
        latestDesktop["LastUse"] = Date().addingTimeInterval(60)
        split["Desktop"] = latestDesktop
        root[key] = split
    }
    try writeWallpaperStore(root, to: fixture.storeURL)

    // Exercise the old journal path; it must not become authoritative for a
    // later Remove.
    _ = try await fixture.installer.rearmForNextLock(videoURL: fixture.videoURL)

    root = try readWallpaperStore(fixture.storeURL)
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        var split = try #require(root[key] as? [String: Any])
        var staleDesktop = AerialLockScreenFixture.makeMode(
            provider: "com.apple.wallpaper.choice.sequoia",
            configuration: [:]
        )
        staleDesktop["LastSet"] = Date().addingTimeInterval(-60)
        staleDesktop["LastUse"] = Date().addingTimeInterval(-60)
        split["Desktop"] = staleDesktop
        root[key] = split
    }
    try writeWallpaperStore(root, to: fixture.storeURL)

    _ = try fixture.installer.activateLockScreenForCurrentSession()
    _ = try fixture.installer.restoreDesktopAfterLockScreenSession()

    root = try readWallpaperStore(fixture.storeURL)
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        let split = try #require(root[key] as? [String: Any])
        let desktop = try #require(split["Desktop"] as? [String: Any])
        #expect(wallpaperStoreContains(
            desktop,
            provider: "com.apple.wallpaper.choice.sequoia",
            assetID: nil
        ))
    }

    // Simulate a journal written by an older build that accidentally kept
    // Aura's managed Idle route next to the newest user Desktop.
    try Data(contentsOf: fixture.storeURL).write(
        to: fixture.stateURL
            .appendingPathComponent("Index.latest-user.plist"),
        options: .atomic
    )

    try fixture.installer.uninstall()

    root = try readWallpaperStore(fixture.storeURL)
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        let restored = try #require(root[key] as? [String: Any])
        #expect(restored["Type"] as? String == "linked")
        #expect(restored["Desktop"] == nil)
        #expect(restored["Idle"] == nil)
        let linked = try #require(restored["Linked"] as? [String: Any])
        #expect(wallpaperStoreContains(
            linked,
            provider: "com.apple.wallpaper.choice.sequoia",
            assetID: nil
        ))
    }
}

@Test func latestUserAerialResolvesItsSystemWallpaperURL() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    let userAssetID = "44166C39-8566-4ECA-BD16-43159429B52F"
    let userMode = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.aerials",
        configuration: ["assetID": userAssetID]
    )
    let container: [String: Any] = [
        "Type": "linked",
        "Linked": userMode,
    ]
    let root: [String: Any] = [
        "AllSpacesAndDisplays": container,
        "SystemDefault": container,
        "Displays": [String: Any](),
        "Spaces": [String: Any](),
    ]
    try writeWallpaperStore(root, to: fixture.storeURL)

    let resolved = fixture.installer.latestUserSystemWallpaperURL(
        from: try Data(contentsOf: fixture.storeURL),
        managedAssetID: AerialLockScreenFixture.assetID
    )

    #expect(
        resolved
            == fixture.videosURL
                .appendingPathComponent(userAssetID)
                .appendingPathExtension("mov")
                .standardizedFileURL.absoluteString
    )
}

@Test func sharedRemoveRepairsOpaqueDownloadedImageConfiguration() throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    let downloadedImageURL = URL(
        fileURLWithPath: "/Users/test/Downloads/opaque-wallpaper.jpg"
    ).standardizedFileURL
    let opaqueImageMode: [String: Any] = [
        "LastSet": Date(),
        "LastUse": Date(),
        "Content": [
            "Choices": [[
                "Provider": WallpaperPlatformConstants.imageProviderID,
                // Recent macOS builds can leave the image descriptor opaque
                // after the user changes Desktop while Aura is running.
                "Files": [],
                "Configuration": Data("opaque-image-config".utf8),
            ]],
            "Shuffle": "$null",
            "EncodedOptionValues": "$null",
        ],
    ]
    var root = try readWallpaperStore(fixture.storeURL)
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        var container = try #require(root[key] as? [String: Any])
        container["Desktop"] = opaqueImageMode
        root[key] = container
    }
    let currentData = try PropertyListSerialization.data(
        fromPropertyList: root,
        format: .binary,
        options: 0
    )
    let transaction = WallpaperStoreTransaction(
        fileManager: .default,
        wallpaperStoreURL: fixture.storeURL,
        spacesPreferencesURL: fixture.spacesURL,
        aerialVideosURL: fixture.videosURL
    )

    let restoredData = try transaction
        .captureLatestUserWallpaperStoreData(
            from: currentData,
            fallbackData: currentData,
            managedAssetID: AerialLockScreenFixture.assetID,
            propagateGlobalDesktopChanges: true,
            userSystemWallpaperURL: downloadedImageURL.absoluteString
        )
    let restoredRoot = try PropertyListSerialization.propertyList(
        from: restoredData,
        options: [],
        format: nil
    ) as? [String: Any]

    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        let container = try #require(restoredRoot?[key] as? [String: Any])
        let desktop = try #require(container["Desktop"] as? [String: Any])
        let content = try #require(desktop["Content"] as? [String: Any])
        let choice = try #require(
            (content["Choices"] as? [[String: Any]])?.first
        )
        let files = try #require(choice["Files"] as? [[String: Any]])
        #expect(files.first?["relative"] as? String
            == downloadedImageURL.absoluteString)

        let configurationData = try #require(
            choice["Configuration"] as? Data
        )
        let configuration = try #require(
            PropertyListSerialization.propertyList(
                from: configurationData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        #expect(configuration["type"] as? String == "imageFile")
        #expect(
            (configuration["url"] as? [String: Any])?["relative"]
                as? String == downloadedImageURL.absoluteString
        )
    }
}

@Test func lockOnlyRemoveMirrorsTheLiveDesktopWithoutReplayingSnapshots() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    // Exercise many user changes while Aura remains installed. Only the last
    // live Desktop route is allowed to matter to Remove.
    for revision in 1...100 {
        var root = try readWallpaperStore(fixture.storeURL)
        root = replaceTestDesktopModes(
            in: root,
            provider: "com.apple.wallpaper.choice.user-\(revision)"
        )
        try writeWallpaperStore(root, to: fixture.storeURL)
    }

    let refreshCountBeforeRemove = fixture.refreshCounter.count
    let raceProvider = "com.apple.wallpaper.choice.user-race-winner"
    var hookCalls = 0
    fixture.installer.lockOnlyRemovalCommitHook = {
        hookCalls += 1
        guard hookCalls == 1,
              var root = try? readWallpaperStore(fixture.storeURL)
        else {
            return
        }
        root = replaceTestDesktopModes(
            in: root,
            provider: raceProvider
        )
        try? writeWallpaperStore(root, to: fixture.storeURL)
    }

    try fixture.installer
        .uninstallLockScreenOnlyPreservingCurrentDesktop()

    let root = try readWallpaperStore(fixture.storeURL)
    let containers = testWallpaperContainers(in: root)
    #expect(!containers.isEmpty)
    for container in containers {
        if (container["Type"] as? String) == "linked" {
            let linked = try #require(
                container["Linked"] as? [String: Any]
            )
            #expect(wallpaperStoreContains(
                linked,
                provider: raceProvider,
                assetID: nil
            ))
            continue
        }
        let desktop = try #require(
            container["Desktop"] as? [String: Any]
        )
        let idle = try #require(container["Idle"] as? [String: Any])
        #expect(wallpaperModeData(desktop) == wallpaperModeData(idle))
        #expect(wallpaperStoreContains(
            desktop,
            provider: raceProvider,
            assetID: nil
        ))
    }
    #expect(!wallpaperStoreContains(
        root,
        provider: "com.apple.wallpaper.choice.aerials",
        assetID: AerialLockScreenFixture.assetID
    ))
    #expect(hookCalls >= 2)
    #expect(fixture.refreshCounter.count == refreshCountBeforeRemove)
    #expect(!fixture.installer.isInstalled)
    #expect(
        try Data(contentsOf: fixture.assetURL)
            == Data("original-aerial".utf8)
    )
}

@Test func lockOnlyRemoveKeepsAnAlreadyLinkedUserRoute() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    var root = try readWallpaperStore(fixture.storeURL)
    let linkedMode = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.sonoma",
        configuration: [:]
    )
    let linkedContainer: [String: Any] = [
        "Type": "linked",
        "Linked": linkedMode,
    ]
    root["AllSpacesAndDisplays"] = linkedContainer
    root["SystemDefault"] = linkedContainer
    root["Displays"] = [String: Any]()
    root["Spaces"] = [String: Any]()
    try writeWallpaperStore(root, to: fixture.storeURL)
    let expectedMode = wallpaperModeData(linkedMode)
    let refreshCountBeforeRemove = fixture.refreshCounter.count

    try fixture.installer
        .uninstallLockScreenOnlyPreservingCurrentDesktop()

    root = try readWallpaperStore(fixture.storeURL)
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        let container = try #require(root[key] as? [String: Any])
        let linked = try #require(
            container["Linked"] as? [String: Any]
        )
        #expect(wallpaperModeData(linked) == expectedMode)
        #expect(container["Desktop"] == nil)
        #expect(container["Idle"] == nil)
    }
    #expect(fixture.refreshCounter.count == refreshCountBeforeRemove)
}

@Test func lockOnlyRemoveAcceptsRestoredWallpaperAsCurrentDesktop() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    var root = try readWallpaperStore(fixture.storeURL)
    let restoredDesktop = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.image",
        configuration: [
            "type": "imageFile",
            "url": [
                "relative":
                    "file:///Users/test/Library/Application%20Support/"
                    + "AuraFlow/Restored%20Wallpapers/current.jpeg",
            ],
        ]
    )
    let expectedMode = wallpaperModeData(restoredDesktop)
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        var container = try #require(root[key] as? [String: Any])
        container["Desktop"] = restoredDesktop
        root[key] = container
    }
    try writeWallpaperStore(root, to: fixture.storeURL)
    let refreshCountBeforeRemove = fixture.refreshCounter.count

    try fixture.installer
        .uninstallLockScreenOnlyPreservingCurrentDesktop()

    root = try readWallpaperStore(fixture.storeURL)
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        let container = try #require(root[key] as? [String: Any])
        let desktop = try #require(
            container["Desktop"] as? [String: Any]
        )
        let idle = try #require(container["Idle"] as? [String: Any])
        #expect(wallpaperModeData(desktop) == expectedMode)
        #expect(wallpaperModeData(idle) == expectedMode)
    }
    #expect(fixture.refreshCounter.count == refreshCountBeforeRemove)
    #expect(!fixture.installer.isInstalled)
}

@Test func lockOnlyRemovePreservesDistinctSpaceAndDisplayDesktops() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    var root = try readWallpaperStore(fixture.storeURL)
    root = replaceTestDesktopModesDistinctly(in: root)
    try writeWallpaperStore(root, to: fixture.storeURL)
    let expectedDesktopRoutes = testDesktopRouteData(in: root)
    #expect(expectedDesktopRoutes.count > 2)
    let refreshCountBeforeRemove = fixture.refreshCounter.count

    try fixture.installer
        .uninstallLockScreenOnlyPreservingCurrentDesktop()

    root = try readWallpaperStore(fixture.storeURL)
    #expect(testDesktopRouteData(in: root) == expectedDesktopRoutes)
    for container in testWallpaperContainers(in: root) {
        guard let desktop = container["Desktop"] as? [String: Any]
        else { continue }
        let idle = try #require(container["Idle"] as? [String: Any])
        #expect(wallpaperModeData(desktop) == wallpaperModeData(idle))
    }
    #expect(fixture.refreshCounter.count == refreshCountBeforeRemove)
}

@Test func lockOnlyRemoveAcceptsIdleOnlyAggregateContainer() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    var root = try readWallpaperStore(fixture.storeURL)
    var aggregate = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    // Current macOS can keep the aggregate route as Idle-only while the
    // concrete Display and Space containers own the user Desktop routes.
    // That is a valid topology and must not make Remove fail closed.
    aggregate.removeValue(forKey: "Desktop")
    aggregate.removeValue(forKey: "Linked")
    aggregate["Type"] = "idle"
    root["AllSpacesAndDisplays"] = aggregate
    try writeWallpaperStore(root, to: fixture.storeURL)
    let expectedDesktopRoutes = testDesktopRouteData(in: root)
    #expect(!expectedDesktopRoutes.isEmpty)

    try fixture.installer
        .uninstallLockScreenOnlyPreservingCurrentDesktop()

    let restoredRoot = try readWallpaperStore(fixture.storeURL)
    #expect(testDesktopRouteData(in: restoredRoot) == expectedDesktopRoutes)
    let restoredAggregate = try #require(
        restoredRoot["AllSpacesAndDisplays"] as? [String: Any]
    )
    let restoredIdle = try #require(
        restoredAggregate["Idle"] as? [String: Any]
    )
    #expect(!wallpaperStoreContains(
        restoredIdle,
        provider: "com.apple.wallpaper.choice.aerials",
        assetID: AerialLockScreenFixture.assetID
    ))
    #expect(!wallpaperStoreContains(
        restoredRoot,
        provider: "com.apple.wallpaper.choice.aerials",
        assetID: AerialLockScreenFixture.assetID
    ))
    #expect(!fixture.installer.isInstalled)
}

@Test func lockOnlyRemoveNeverReplaysBackupWhenMarkerIsCorrupt() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    let liveDesktopStore = try Data(contentsOf: fixture.storeURL)
    try Data("{broken-marker".utf8).write(
        to: fixture.stateURL.appendingPathComponent("installation.json"),
        options: .atomic
    )

    #expect(throws: AerialLockScreenInstallerError.self) {
        try fixture.installer
            .uninstallLockScreenOnlyPreservingCurrentDesktop()
    }
    #expect(try Data(contentsOf: fixture.storeURL) == liveDesktopStore)
}

@Test func modernLockScreenOnlyPromotesAndRestoresDesktopRoute() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    #expect(fixture.installer.isLockScreenOnlyInstallation)

    var root = try readWallpaperStore(fixture.storeURL)
    var allSpacesAndDisplays = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    let promoted = try fixture.installer
        .activateLockScreenForCurrentSession()
    #expect(promoted)
    #expect(fixture.refreshCounter.count == 2)
    root = try readWallpaperStore(fixture.storeURL)
    allSpacesAndDisplays = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    let lockDesktop = try #require(
        allSpacesAndDisplays["Desktop"] as? [String: Any]
    )
    #expect(wallpaperStoreContains(
        lockDesktop,
        provider: "com.apple.wallpaper.choice.aerials",
        assetID: AerialLockScreenFixture.assetID
    ))

    _ = try fixture.installer.restoreDesktopAfterLockScreenSession()
    root = try readWallpaperStore(fixture.storeURL)
    allSpacesAndDisplays = try #require(
        root["AllSpacesAndDisplays"] as? [String: Any]
    )
    let restoredDesktop = try #require(
        allSpacesAndDisplays["Desktop"] as? [String: Any]
    )
    #expect(wallpaperStoreContains(
        restoredDesktop,
        provider: "com.apple.wallpaper.choice.image",
        assetID: nil
    ))
    #expect(fixture.installer.isLockScreenOnlyInstallation)
}

@Test func modernLockScreenOnlyRestoresLatestUserDesktopRoute() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    var changedRoot = try readWallpaperStore(fixture.storeURL)
    var changedContainer = try #require(
        changedRoot["AllSpacesAndDisplays"] as? [String: Any]
    )
    var changedDesktop = try #require(
        changedContainer["Desktop"] as? [String: Any]
    )
    var changedContent = try #require(
        changedDesktop["Content"] as? [String: Any]
    )
    var changedChoices = try #require(
        changedContent["Choices"] as? [[String: Any]]
    )
    changedChoices[0]["Provider"] = "com.apple.wallpaper.choice.sequoia"
    changedChoices[0]["Configuration"] = Data()
    changedChoices[0]["Files"] = []
    changedContent["Choices"] = changedChoices
    changedDesktop["Content"] = changedContent
    changedContainer["Desktop"] = changedDesktop
    changedRoot["AllSpacesAndDisplays"] = changedContainer
    try writeWallpaperStore(changedRoot, to: fixture.storeURL)

    _ = try fixture.installer.activateLockScreenForCurrentSession()
    _ = try fixture.installer.restoreDesktopAfterLockScreenSession()
    _ = try fixture.installer.restoreDesktopAfterLockScreenSession()

    let restoredRoot = try readWallpaperStore(fixture.storeURL)
    let restoredContainer = try #require(
        restoredRoot["AllSpacesAndDisplays"] as? [String: Any]
    )
    let restoredDesktop = try #require(
        restoredContainer["Desktop"] as? [String: Any]
    )
    #expect(wallpaperStoreContains(
        restoredDesktop,
        provider: "com.apple.wallpaper.choice.sequoia",
        assetID: nil
    ))
}

@Test func lockOnlyRestoreDoesNotReplaySnapshotWithoutActiveLock() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    var changedRoot = try readWallpaperStore(fixture.storeURL)
    var changedContainer = try #require(
        changedRoot["AllSpacesAndDisplays"] as? [String: Any]
    )
    changedContainer["Desktop"] = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.sequoia",
        configuration: [:]
    )
    changedRoot["AllSpacesAndDisplays"] = changedContainer
    try writeWallpaperStore(changedRoot, to: fixture.storeURL)
    let userStoreData = try Data(contentsOf: fixture.storeURL)

    let restored = try fixture.installer
        .restoreDesktopAfterLockScreenSession()

    #expect(!restored)
    #expect(try Data(contentsOf: fixture.storeURL) == userStoreData)
}

@Test func modernLockScreenOnlyUninstallKeepsDesktopChangedByUser() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    var changedRoot = try readWallpaperStore(fixture.storeURL)
    func withDesktop(_ value: Any?, provider: String) throws -> [String: Any] {
        var container = try #require(value as? [String: Any])
        container["Desktop"] = AerialLockScreenFixture.makeMode(
            provider: provider,
            configuration: [:]
        )
        return container
    }
    changedRoot["AllSpacesAndDisplays"] = try withDesktop(
        changedRoot["AllSpacesAndDisplays"],
        provider: "com.apple.wallpaper.choice.sequoia"
    )
    var mixedSystemDefault = try #require(
        changedRoot["SystemDefault"] as? [String: Any]
    )
    mixedSystemDefault["Desktop"] = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.aerials",
        configuration: ["assetID": AerialLockScreenFixture.assetID]
    )
    changedRoot["SystemDefault"] = mixedSystemDefault
    var changedDisplays = try #require(
        changedRoot["Displays"] as? [String: Any]
    )
    changedDisplays[AerialLockScreenFixture.displayID] = try withDesktop(
        changedDisplays[AerialLockScreenFixture.displayID],
        provider: "com.apple.wallpaper.choice.sonoma"
    )
    changedRoot["Displays"] = changedDisplays
    var changedSpaces = try #require(
        changedRoot["Spaces"] as? [String: Any]
    )
    var changedSpace = try #require(
        changedSpaces[AerialLockScreenFixture.activeSpaceID]
            as? [String: Any]
    )
    changedSpace["Default"] = try withDesktop(
        changedSpace["Default"],
        provider: "com.apple.wallpaper.choice.monterey"
    )
    var changedSpaceDisplays = try #require(
        changedSpace["Displays"] as? [String: Any]
    )
    changedSpaceDisplays[AerialLockScreenFixture.displayID] = try withDesktop(
        changedSpaceDisplays[AerialLockScreenFixture.displayID],
        provider: "com.apple.wallpaper.choice.big-sur"
    )
    changedSpace["Displays"] = changedSpaceDisplays
    changedSpaces[AerialLockScreenFixture.activeSpaceID] = changedSpace
    changedRoot["Spaces"] = changedSpaces
    try writeWallpaperStore(changedRoot, to: fixture.storeURL)

    try fixture.installer.uninstall()

    let restoredRoot = try readWallpaperStore(fixture.storeURL)
    func expectDesktop(_ value: Any?, provider: String) throws {
        let container = try #require(value as? [String: Any])
        let desktop = try #require(container["Desktop"] as? [String: Any])
        #expect(wallpaperStoreContains(
            desktop,
            provider: provider,
            assetID: nil
        ))
    }
    let restoredContainer = try #require(
        restoredRoot["AllSpacesAndDisplays"] as? [String: Any]
    )
    try expectDesktop(
        restoredContainer,
        provider: "com.apple.wallpaper.choice.sequoia"
    )
    try expectDesktop(
        restoredRoot["SystemDefault"],
        provider: "com.apple.wallpaper.choice.image"
    )
    let restoredDisplays = try #require(
        restoredRoot["Displays"] as? [String: Any]
    )
    try expectDesktop(
        restoredDisplays[AerialLockScreenFixture.displayID],
        provider: "com.apple.wallpaper.choice.sonoma"
    )
    let restoredSpaces = try #require(
        restoredRoot["Spaces"] as? [String: Any]
    )
    let restoredSpace = try #require(
        restoredSpaces[AerialLockScreenFixture.activeSpaceID]
            as? [String: Any]
    )
    try expectDesktop(
        restoredSpace["Default"],
        provider: "com.apple.wallpaper.choice.monterey"
    )
    let restoredSpaceDisplays = try #require(
        restoredSpace["Displays"] as? [String: Any]
    )
    try expectDesktop(
        restoredSpaceDisplays[AerialLockScreenFixture.displayID],
        provider: "com.apple.wallpaper.choice.big-sur"
    )
    let restoredIdle = try #require(restoredContainer["Idle"] as? [String: Any])
    #expect(wallpaperStoreContains(
        restoredIdle,
        provider: "com.apple.wallpaper.choice.screen-saver",
        assetID: nil
    ))
    #expect(!wallpaperStoreText(restoredRoot).contains("AuraFlow"))
}

@Test func modernLockScreenUninstallRestoresCleanStoreAndAerialAsset() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.install(videoURL: fixture.videoURL)
    let exactStoreBackup = try Data(
        contentsOf: fixture.stateURL
            .appendingPathComponent("Index.before-auraflow.plist")
    )
    try await fixture.installer.uninstallAsync()

    #expect(!fixture.installer.isInstalled)
    #expect(try Data(contentsOf: fixture.storeURL) == exactStoreBackup)
    #expect(
        try Data(contentsOf: fixture.assetURL)
            == Data("original-aerial".utf8)
    )
    let root = try readWallpaperStore(fixture.storeURL)
    #expect(!wallpaperStoreText(root).contains("last_frame"))
    #expect(!wallpaperStoreText(root).contains("AuraFlowLockScreen"))
    #expect(
        wallpaperStoreContains(
            root,
            provider: "com.apple.wallpaper.choice.screen-saver",
            assetID: nil
        )
    )
}

@Test func modernSharedRemoveRestoresDesktopChangedWhileAuraRuns() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.install(videoURL: fixture.videoURL)

    var latestRoot = try readWallpaperStore(fixture.storeURL)
    let latestUserDesktop = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.sequoia",
        configuration: [
            "type": "imageFile",
            "url": ["relative": "file:///latest-user-wallpaper.jpg"],
        ]
    )
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        var container = try #require(latestRoot[key] as? [String: Any])
        container["Desktop"] = latestUserDesktop
        latestRoot[key] = container
    }
    try writeWallpaperStore(latestRoot, to: fixture.storeURL)

    try fixture.installer.uninstall()

    let restoredRoot = try readWallpaperStore(fixture.storeURL)
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        let container = try #require(restoredRoot[key] as? [String: Any])
        let desktop = try #require(container["Desktop"] as? [String: Any])
        #expect(wallpaperModeData(desktop) == wallpaperModeData(latestUserDesktop))
    }
    #expect(!wallpaperStoreText(restoredRoot).contains("AuraFlow"))
    #expect(!fixture.installer.isInstalled)
}

@Test func modernSharedRemoveUsesDesktopJournalAfterAgentRewritesStore() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.install(videoURL: fixture.videoURL)
    let managedStoreData = try Data(contentsOf: fixture.storeURL)
    var latestRoot = try readWallpaperStore(fixture.storeURL)
    let latestUserDesktop = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.sequoia",
        configuration: [
            "type": "imageFile",
            "url": ["relative": "file:///journaled-user-wallpaper.jpg"],
        ]
    )
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        var container = try #require(latestRoot[key] as? [String: Any])
        container["Desktop"] = latestUserDesktop
        latestRoot[key] = container
    }
    try writeWallpaperStore(latestRoot, to: fixture.storeURL)

    let latestUserStoreURL = fixture.stateURL
        .appendingPathComponent("Index.latest-user.plist")
    var captured = false
    for _ in 0..<10 {
        if FileManager.default.fileExists(atPath: latestUserStoreURL.path) {
            captured = true
            break
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(captured)

    // WallpaperAgent can restore its managed Aerial snapshot before the user
    // presses Remove. The journal must still win in that case.
    try managedStoreData.write(to: fixture.storeURL, options: .atomic)
    try await Task.sleep(nanoseconds: 120_000_000)
    try fixture.installer.uninstall()

    let restoredRoot = try readWallpaperStore(fixture.storeURL)
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        let container = try #require(restoredRoot[key] as? [String: Any])
        let desktop = try #require(container["Desktop"] as? [String: Any])
        #expect(wallpaperModeData(desktop) == wallpaperModeData(latestUserDesktop))
    }
    #expect(!wallpaperStoreText(restoredRoot).contains("AuraFlow"))
    #expect(!fixture.installer.isInstalled)
}

@Test func modernSharedRemoveUsesConcreteDesktopJournalAfterAgentRewritesStore() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.install(videoURL: fixture.videoURL)
    let managedStoreData = try Data(contentsOf: fixture.storeURL)
    var latestRoot = try readWallpaperStore(fixture.storeURL)
    var latestUserDesktop = AerialLockScreenFixture.makeMode(
        provider: WallpaperPlatformConstants.imageProviderID,
        configuration: [
            "type": "imageFile",
            "url": ["relative": "file:///journaled-space-wallpaper.jpg"],
        ]
    )
    var latestContent = try #require(
        latestUserDesktop["Content"] as? [String: Any]
    )
    var latestChoices = try #require(
        latestContent["Choices"] as? [[String: Any]]
    )
    latestChoices[0]["Files"] = [[
        "relative": "file:///journaled-space-wallpaper.jpg",
    ]]
    latestContent["Choices"] = latestChoices
    latestUserDesktop["Content"] = latestContent
    var spaces = try #require(latestRoot["Spaces"] as? [String: Any])
    var activeSpace = try #require(
        spaces[AerialLockScreenFixture.activeSpaceID] as? [String: Any]
    )
    var activeDefault = try #require(
        activeSpace["Default"] as? [String: Any]
    )
    activeDefault["Desktop"] = latestUserDesktop
    activeSpace["Default"] = activeDefault
    var spaceDisplays = try #require(
        activeSpace["Displays"] as? [String: Any]
    )
    var activeDisplay = try #require(
        spaceDisplays[AerialLockScreenFixture.displayID] as? [String: Any]
    )
    activeDisplay["Desktop"] = latestUserDesktop
    spaceDisplays[AerialLockScreenFixture.displayID] = activeDisplay
    activeSpace["Displays"] = spaceDisplays
    spaces[AerialLockScreenFixture.activeSpaceID] = activeSpace
    latestRoot["Spaces"] = spaces
    try writeWallpaperStore(latestRoot, to: fixture.storeURL)

    let latestUserStoreURL = fixture.stateURL
        .appendingPathComponent("Index.latest-user.plist")
    var captured = false
    for _ in 0..<20 {
        if FileManager.default.fileExists(atPath: latestUserStoreURL.path) {
            captured = true
            break
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(captured)

    // Simulate WallpaperAgent replacing the live store with its temporary
    // global Aerial route before Remove is pressed.
    try managedStoreData.write(to: fixture.storeURL, options: .atomic)
    try await Task.sleep(nanoseconds: 120_000_000)
    try fixture.installer.uninstall()

    let restoredRoot = try readWallpaperStore(fixture.storeURL)
    let restoredSpaces = try #require(
        restoredRoot["Spaces"] as? [String: Any]
    )
    let restoredSpace = try #require(
        restoredSpaces[AerialLockScreenFixture.activeSpaceID]
            as? [String: Any]
    )
    let restoredDefault = try #require(
        restoredSpace["Default"] as? [String: Any]
    )
    let restoredDesktop = try #require(
        restoredDefault["Desktop"] as? [String: Any]
    )
    #expect(wallpaperModeData(restoredDesktop) == wallpaperModeData(latestUserDesktop))
    let restoredDisplays = try #require(
        restoredSpace["Displays"] as? [String: Any]
    )
    let restoredDisplay = try #require(
        restoredDisplays[AerialLockScreenFixture.displayID]
            as? [String: Any]
    )
    let restoredDisplayDesktop = try #require(
        restoredDisplay["Desktop"] as? [String: Any]
    )
    #expect(
        wallpaperModeData(restoredDisplayDesktop)
            == wallpaperModeData(latestUserDesktop)
    )
    #expect(!wallpaperStoreText(restoredRoot).contains("AuraFlow"))
    #expect(!fixture.installer.isInstalled)
}

@Test func modernSharedRemovePreservesDownloadedImageRouteAfterAgentRewritesStore() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.install(videoURL: fixture.videoURL)
    let managedStoreData = try Data(contentsOf: fixture.storeURL)
    var latestRoot = try readWallpaperStore(fixture.storeURL)
    let downloadedImageURL = URL(
        fileURLWithPath: "/Users/test/Downloads/aura-wallpaper.jpg"
    ).standardizedFileURL
    let imageMode = AerialLockScreenFixture.makeMode(
        provider: WallpaperPlatformConstants.imageProviderID,
        configuration: [
            "type": "imageFile",
            "url": ["relative": downloadedImageURL.absoluteString],
        ]
    )
    var imageContent = try #require(imageMode["Content"] as? [String: Any])
    var imageChoices = try #require(
        imageContent["Choices"] as? [[String: Any]]
    )
    imageChoices[0]["Files"] = [["relative": downloadedImageURL.absoluteString]]
    imageContent["Choices"] = imageChoices
    var downloadedImageMode = imageMode
    downloadedImageMode["Content"] = imageContent
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        var container = try #require(latestRoot[key] as? [String: Any])
        container["Desktop"] = downloadedImageMode
        latestRoot[key] = container
    }
    try writeWallpaperStore(latestRoot, to: fixture.storeURL)

    let latestUserStoreURL = fixture.stateURL
        .appendingPathComponent("Index.latest-user.plist")
    var captured = false
    for _ in 0..<20 {
        if FileManager.default.fileExists(atPath: latestUserStoreURL.path) {
            captured = true
            break
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(captured)

    try managedStoreData.write(to: fixture.storeURL, options: .atomic)
    try await Task.sleep(nanoseconds: 120_000_000)
    try fixture.installer.uninstall()

    let restoredRoot = try readWallpaperStore(fixture.storeURL)
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        let container = try #require(restoredRoot[key] as? [String: Any])
        let desktop = try #require(container["Desktop"] as? [String: Any])
        #expect(
            wallpaperModeData(desktop) == wallpaperModeData(downloadedImageMode),
            "unexpected restored Desktop route for \(key)"
        )
    }
    #expect(!wallpaperStoreText(restoredRoot).contains("AuraFlow"))
    #expect(!fixture.installer.isInstalled)
}

@Test func modernSharedRemovePropagatesDownloadedImageFromSystemDefault() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.install(videoURL: fixture.videoURL)
    let managedStoreData = try Data(contentsOf: fixture.storeURL)
    var latestRoot = try readWallpaperStore(fixture.storeURL)
    let downloadedImageURL = URL(
        fileURLWithPath: "/Users/test/Downloads/latest-aura-wallpaper.jpg"
    ).standardizedFileURL
    let imageMode = AerialLockScreenFixture.makeMode(
        provider: WallpaperPlatformConstants.imageProviderID,
        configuration: [
            "type": "imageFile",
            "url": ["relative": downloadedImageURL.absoluteString],
        ]
    )
    var imageContent = try #require(imageMode["Content"] as? [String: Any])
    var imageChoices = try #require(
        imageContent["Choices"] as? [[String: Any]]
    )
    imageChoices[0]["Files"] = [["relative": downloadedImageURL.absoluteString]]
    imageContent["Choices"] = imageChoices
    var downloadedImageMode = imageMode
    downloadedImageMode["Content"] = imageContent

    // This is the topology produced by WallpaperAgent while a shared Aura
    // route is still active: the user's new image exists in SystemDefault,
    // while AllSpacesAndDisplays still points at Aura's Aerial route.
    var systemDefault = try #require(
        latestRoot["SystemDefault"] as? [String: Any]
    )
    systemDefault["Desktop"] = downloadedImageMode
    latestRoot["SystemDefault"] = systemDefault
    try writeWallpaperStore(latestRoot, to: fixture.storeURL)

    let latestUserStoreURL = fixture.stateURL
        .appendingPathComponent("Index.latest-user.plist")
    var captured = false
    for _ in 0..<20 {
        if FileManager.default.fileExists(atPath: latestUserStoreURL.path) {
            captured = true
            break
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(captured)

    try managedStoreData.write(to: fixture.storeURL, options: .atomic)
    try await Task.sleep(nanoseconds: 120_000_000)
    try fixture.installer.uninstall()

    let restoredRoot = try readWallpaperStore(fixture.storeURL)
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        let container = try #require(restoredRoot[key] as? [String: Any])
        let desktop = try #require(container["Desktop"] as? [String: Any])
        #expect(
            wallpaperModeData(desktop) == wallpaperModeData(downloadedImageMode),
            "unexpected restored Desktop route for \(key)"
        )
    }
    #expect(!wallpaperStoreText(restoredRoot).contains("AuraFlow"))
    #expect(!fixture.installer.isInstalled)
}

@Test func healthyModernLockScreenSyncIsANoOp() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.install(videoURL: fixture.videoURL)
    #expect(fixture.refreshCounter.count == 1)

    try await fixture.installer.install(videoURL: fixture.videoURL)
    #expect(fixture.refreshCounter.count == 1)
    let providers = wallpaperChoiceProviders(
        try readWallpaperStore(fixture.storeURL)
    )
    #expect(
        providers == Array(
            repeating: "com.apple.wallpaper.choice.aerials",
            count: providers.count
        )
    )
}

@Test func modernLockScreenRearmsProviderAfterEveryUnlock() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.install(videoURL: fixture.videoURL)
    let exactStoreBackupURL = fixture.stateURL
        .appendingPathComponent("Index.before-auraflow.plist")
    let exactStoreBackup = try Data(contentsOf: exactStoreBackupURL)
    let installedStore = try Data(contentsOf: fixture.storeURL)

    for expectedRefreshCount in 2...12 {
        try await fixture.installer.rearmForNextLock(
            videoURL: fixture.videoURL
        )
        #expect(
            fixture.refreshCounter.count == expectedRefreshCount
        )
        #expect(
            try Data(contentsOf: exactStoreBackupURL)
                == exactStoreBackup
        )
        #expect(try Data(contentsOf: fixture.storeURL) == installedStore)
        #expect(
            try Data(contentsOf: fixture.assetURL)
                == Data("new-wallpaper".utf8)
        )
        let providers = wallpaperChoiceProviders(
            try readWallpaperStore(fixture.storeURL)
        )
        #expect(!providers.isEmpty)
        #expect(
            providers.allSatisfy {
                $0 == "com.apple.wallpaper.choice.aerials"
            }
        )
    }
}

@Test func cancelledModernLockScreenRearmDoesNotRefreshProvider() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.install(videoURL: fixture.videoURL)
    let installedStore = try Data(contentsOf: fixture.storeURL)

    let didRearm = try await fixture.installer.rearmForNextLock(
        videoURL: fixture.videoURL,
        shouldProceed: { false }
    )

    #expect(!didRearm)
    #expect(fixture.refreshCounter.count == 1)
    #expect(try Data(contentsOf: fixture.storeURL) == installedStore)
    #expect(
        try Data(contentsOf: fixture.assetURL)
            == Data("new-wallpaper".utf8)
    )
}

@Test func lockDuringModernLockScreenRepairRollsBackWithoutRefresh() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.install(videoURL: fixture.videoURL)
    let installedStore = try Data(contentsOf: fixture.storeURL)
    let tamperedAsset = Data("tampered-during-session".utf8)
    try tamperedAsset.write(to: fixture.assetURL, options: .atomic)
    let gate = AerialProceedGate(allowedCalls: 1)

    let didRepair = try await fixture.installer.repair(
        videoURL: fixture.videoURL,
        shouldProceed: gate.shouldProceed
    )

    #expect(!didRepair)
    #expect(fixture.refreshCounter.count == 1)
    #expect(try Data(contentsOf: fixture.storeURL) == installedStore)
    #expect(try Data(contentsOf: fixture.assetURL) == tamperedAsset)
}

@Test func cancellationAfterJournalDoesNotTouchSystemFiles() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.install(videoURL: fixture.videoURL)
    let installedStore = try Data(contentsOf: fixture.storeURL)
    let tamperedAsset = Data("tampered-before-journal-cancel".utf8)
    try tamperedAsset.write(to: fixture.assetURL, options: .atomic)
    let sentinelDate = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes(
        [.modificationDate: sentinelDate],
        ofItemAtPath: fixture.storeURL.path
    )
    try FileManager.default.setAttributes(
        [.modificationDate: sentinelDate],
        ofItemAtPath: fixture.assetURL.path
    )
    let gate = AerialProceedGate(allowedCalls: 2)

    let didRepair = try await fixture.installer.repair(
        videoURL: fixture.videoURL,
        shouldProceed: gate.shouldProceed
    )

    let storeAttributes = try FileManager.default.attributesOfItem(
        atPath: fixture.storeURL.path
    )
    let assetAttributes = try FileManager.default.attributesOfItem(
        atPath: fixture.assetURL.path
    )
    #expect(!didRepair)
    #expect(fixture.refreshCounter.count == 1)
    #expect(try Data(contentsOf: fixture.storeURL) == installedStore)
    #expect(try Data(contentsOf: fixture.assetURL) == tamperedAsset)
    #expect(storeAttributes[.modificationDate] as? Date == sentinelDate)
    #expect(assetAttributes[.modificationDate] as? Date == sentinelDate)
}

@Test func modernLockScreenRepairsTamperedAssetAndStore() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.install(videoURL: fixture.videoURL)
    try Data(repeating: 0x5A, count: 13).write(
        to: fixture.assetURL,
        options: .atomic
    )

    var root = try readWallpaperStore(fixture.storeURL)
    var systemDefault = try #require(
        root["SystemDefault"] as? [String: Any]
    )
    systemDefault["Desktop"] = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.image",
        configuration: [
            "type": "imageFile",
            "url": ["relative": "file:///tampered.jpg"],
        ]
    )
    root["SystemDefault"] = systemDefault
    try writeWallpaperStore(root, to: fixture.storeURL)

    try await fixture.installer.install(videoURL: fixture.videoURL)

    #expect(fixture.refreshCounter.count == 2)
    #expect(
        try Data(contentsOf: fixture.assetURL)
            == Data("new-wallpaper".utf8)
    )
    let repairedProviders = wallpaperChoiceProviders(
        try readWallpaperStore(fixture.storeURL)
    )
    #expect(!repairedProviders.isEmpty)
    #expect(
        repairedProviders.allSatisfy {
            $0 == "com.apple.wallpaper.choice.aerials"
        }
    )
}

@Test func modernLockScreenCreatesAndRemovesReservedAssetOnFreshMac() async throws {
    let fixture = try AerialLockScreenFixture(hasExistingAsset: false)
    defer { fixture.cleanup() }

    #expect(fixture.installer.isAvailable)
    #expect(!FileManager.default.fileExists(atPath: fixture.assetURL.path))

    try await fixture.installer.install(videoURL: fixture.videoURL)
    #expect(FileManager.default.fileExists(atPath: fixture.assetURL.path))
    #expect(
        try Data(contentsOf: fixture.assetURL)
            == Data("new-wallpaper".utf8)
    )

    try fixture.installer.uninstall()
    #expect(!FileManager.default.fileExists(atPath: fixture.assetURL.path))
}

@Test func lockOnlyUsesDownloadedUnusedSlotsAndRotatesAfterRemove() async throws {
    let fixture = try AerialLockScreenFixture(
        hasExistingAsset: true,
        providerAssetIDs: [
            AerialLockScreenFixture.assetID,
            AerialLockScreenFixture.alternateAssetID,
            AerialLockScreenFixture.secondAlternateAssetID,
        ],
        downloadedAssetIDs: [
            AerialLockScreenFixture.alternateAssetID,
            AerialLockScreenFixture.secondAlternateAssetID,
        ],
        configuredAssetID: nil
    )
    defer { fixture.cleanup() }

    let assetIDs = [
        AerialLockScreenFixture.assetID,
        AerialLockScreenFixture.alternateAssetID,
        AerialLockScreenFixture.secondAlternateAssetID,
    ]
    let originalAssets = try Dictionary(uniqueKeysWithValues: assetIDs.map {
        let url = fixture.videosURL.appendingPathComponent($0)
            .appendingPathExtension("mov")
        return ($0, try Data(contentsOf: url))
    })
    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    let firstMarker = try #require(
        JSONSerialization.jsonObject(
            with: Data(
                contentsOf: fixture.stateURL
                    .appendingPathComponent("installation.json")
            )
        ) as? [String: Any]
    )
    let firstAssetID = try #require(firstMarker["assetID"] as? String)
    #expect(assetIDs.contains(firstAssetID))

    try fixture.installer
        .uninstallLockScreenOnlyPreservingCurrentDesktop()
    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    let secondMarker = try #require(
        JSONSerialization.jsonObject(
            with: Data(
                contentsOf: fixture.stateURL
                    .appendingPathComponent("installation.json")
            )
        ) as? [String: Any]
    )
    let secondAssetID = try #require(secondMarker["assetID"] as? String)
    #expect(secondAssetID != firstAssetID)
    let firstAssetURL = fixture.videosURL.appendingPathComponent(firstAssetID)
        .appendingPathExtension("mov")
    let secondAssetURL = fixture.videosURL.appendingPathComponent(secondAssetID)
        .appendingPathExtension("mov")
    #expect(try Data(contentsOf: firstAssetURL) == originalAssets[firstAssetID])
    #expect(try Data(contentsOf: secondAssetURL) == Data("new-wallpaper".utf8))
}

@Test func lockOnlyReusesLastManagedSlotWhenRemoveLeavesOnlyReferencedAerial() async throws {
    let fixture = try AerialLockScreenFixture(
        hasExistingAsset: true,
        configuredAssetID: nil
    )
    defer { fixture.cleanup() }

    var store = try readWallpaperStore(fixture.storeURL)
    let referencedAerial = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.aerials",
        configuration: ["assetID": AerialLockScreenFixture.assetID]
    )
    for containerName in ["AllSpacesAndDisplays", "SystemDefault"] {
        guard var container = store[containerName] as? [String: Any] else {
            continue
        }
        container["Idle"] = referencedAerial
        store[containerName] = container
    }
    try writeWallpaperStore(store, to: fixture.storeURL)

    let slotStateURL = fixture.stateURL.deletingLastPathComponent()
        .appendingPathComponent("lock_screen_slot_state.json")
    let slotState = "{\"generation\":83,\"lastAssetID\":\""
        + AerialLockScreenFixture.assetID
        + "\"}"
    try Data(slotState.utf8).write(to: slotStateURL)

    #expect(fixture.installer.isAvailable)
    try await fixture.installer.installLockScreenOnly(
        videoURL: fixture.videoURL
    )

    let marker = try #require(
        JSONSerialization.jsonObject(
            with: Data(
                contentsOf: fixture.stateURL
                    .appendingPathComponent("installation.json")
            )
        ) as? [String: Any]
    )
    #expect(marker["assetID"] as? String == AerialLockScreenFixture.assetID)
    #expect(
        try Data(contentsOf: fixture.assetURL)
            == Data("new-wallpaper".utf8)
    )
}

@Test func lockOnlyIgnoresThumbnailOnlySlots() async throws {
    let fixture = try AerialLockScreenFixture(
        hasExistingAsset: true,
        providerAssetIDs: [
            AerialLockScreenFixture.assetID,
            AerialLockScreenFixture.alternateAssetID,
        ],
        configuredAssetID: nil
    )
    defer { fixture.cleanup() }

    let catalogThumbnail = fixture.thumbnailsURL
        .appendingPathComponent(AerialLockScreenFixture.alternateAssetID)
        .appendingPathExtension("png")
    try Data("catalog-thumbnail".utf8).write(to: catalogThumbnail)
    let originalSystemAsset = try Data(contentsOf: fixture.assetURL)

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)
    let marker = try #require(
        JSONSerialization.jsonObject(
            with: Data(
                contentsOf: fixture.stateURL
                    .appendingPathComponent("installation.json")
            )
        ) as? [String: Any]
    )
    #expect(marker["assetID"] as? String == AerialLockScreenFixture.assetID)

    try fixture.installer
        .uninstallLockScreenOnlyPreservingCurrentDesktop()
    #expect(try Data(contentsOf: fixture.assetURL) == originalSystemAsset)
    #expect(try Data(contentsOf: catalogThumbnail) == Data("catalog-thumbnail".utf8))
}

@Test func modernLockScreenRejectsProviderWithoutReservedAsset() async throws {
    let fixture = try AerialLockScreenFixture(
        hasExistingAsset: false,
        providerHasAsset: false
    )
    defer { fixture.cleanup() }

    #expect(!fixture.installer.isAvailable)
    await expectAsyncThrowing(AerialLockScreenInstallerError.self) {
        try await fixture.installer.install(videoURL: fixture.videoURL)
    }
}

@Test func modernProviderRemovalInvalidatesAvailability() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    #expect(fixture.installer.isAvailable)
    try FileManager.default.removeItem(at: fixture.providerURL)

    #expect(fixture.installer.isAvailable == false)
}

@Test func lockOnlyFailsWithoutOverwritingWhenEverySlotIsOccupied() async throws {
    let fixture = try AerialLockScreenFixture(
        hasExistingAsset: true,
        configuredAssetID: nil
    )
    defer { fixture.cleanup() }

    var occupiedStore = try readWallpaperStore(fixture.storeURL)
    var systemDefault = try #require(
        occupiedStore["SystemDefault"] as? [String: Any]
    )
    systemDefault["Idle"] = AerialLockScreenFixture.makeMode(
        provider: "com.apple.wallpaper.choice.aerials",
        configuration: ["assetID": AerialLockScreenFixture.assetID]
    )
    occupiedStore["SystemDefault"] = systemDefault
    try writeWallpaperStore(occupiedStore, to: fixture.storeURL)
    let storeBefore = try Data(contentsOf: fixture.storeURL)
    let assetBefore = try Data(contentsOf: fixture.assetURL)
    #expect(fixture.installer.isAvailable == false)
    await expectAsyncThrowing(AerialLockScreenInstallerError.self) {
        try await fixture.installer.installLockScreenOnly(
            videoURL: fixture.videoURL
        )
    }
    #expect(try Data(contentsOf: fixture.storeURL) == storeBefore)
    #expect(try Data(contentsOf: fixture.assetURL) == assetBefore)
}

@Test func lockOnlyFallsBackWhenOnlyMissingCatalogSlotsExist() async throws {
    let fixture = try AerialLockScreenFixture(
        hasExistingAsset: false,
        configuredAssetID: nil
    )
    defer { fixture.cleanup() }

    #expect(fixture.installer.isAvailable == false)
    await expectAsyncThrowing(AerialLockScreenInstallerError.self) {
        try await fixture.installer.installLockScreenOnly(
            videoURL: fixture.videoURL
        )
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.assetURL.path))
}

@Test func replacementPreservesAerialDownloaderMetadata() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }
    let sourceURL = Data("https://example.invalid/aerial.mov".utf8)
    let lastETag = Data("test-etag".utf8)
    sourceURL.withUnsafeBytes { bytes in
        let result = fixture.assetURL.path.withCString { path in
            setxattr(path, "SourceURL", bytes.baseAddress, sourceURL.count, 0, 0)
        }
        #expect(result == 0)
    }
    lastETag.withUnsafeBytes { bytes in
        let result = fixture.assetURL.path.withCString { path in
            setxattr(path, "LastETag", bytes.baseAddress, lastETag.count, 0, 0)
        }
        #expect(result == 0)
    }

    try await fixture.installer.installLockScreenOnly(videoURL: fixture.videoURL)

    func attribute(_ name: String) -> Data? {
        let size = fixture.assetURL.path.withCString { path in
            getxattr(path, name, nil, 0, 0, 0)
        }
        guard size >= 0 else { return nil }
        var value = Data(count: size)
        let read = value.withUnsafeMutableBytes { bytes in
            fixture.assetURL.path.withCString { path in
                getxattr(path, name, bytes.baseAddress, size, 0, 0)
            }
        }
        return read == size ? value : nil
    }
    #expect(attribute("SourceURL") == sourceURL)
    #expect(attribute("LastETag") == lastETag)

    try fixture.installer.uninstallLockScreenOnlyPreservingCurrentDesktop()
}

@Test func incompleteModernLockScreenJournalIsRetried() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.install(videoURL: fixture.videoURL)
    let markerURL = fixture.stateURL
        .appendingPathComponent("installation.json")
    let markerData = try Data(contentsOf: markerURL)
    var marker = try #require(
        JSONSerialization.jsonObject(with: markerData)
            as? [String: Any]
    )
    marker["completed"] = false
    try JSONSerialization.data(
        withJSONObject: marker,
        options: [.prettyPrinted, .sortedKeys]
    ).write(to: markerURL, options: .atomic)

    try await fixture.installer.install(videoURL: fixture.videoURL)
    #expect(fixture.refreshCounter.count == 2)
    let completedData = try Data(contentsOf: markerURL)
    let completedMarker = try #require(
        JSONSerialization.jsonObject(with: completedData)
            as? [String: Any]
    )
    #expect(completedMarker["completed"] as? Bool == true)
}

@Test func corruptModernLockScreenMarkerStillRestoresBackup() async throws {
    let fixture = try AerialLockScreenFixture()
    defer { fixture.cleanup() }

    try await fixture.installer.install(videoURL: fixture.videoURL)
    let exactStoreBackup = try Data(
        contentsOf: fixture.stateURL
            .appendingPathComponent("Index.before-auraflow.plist")
    )
    let markerURL = fixture.stateURL
        .appendingPathComponent("installation.json")
    try Data("{not-json".utf8).write(
        to: markerURL,
        options: .atomic
    )

    try fixture.installer.uninstall()

    #expect(!fixture.installer.isInstalled)
    #expect(try Data(contentsOf: fixture.storeURL) == exactStoreBackup)
    #expect(
        try Data(contentsOf: fixture.assetURL)
            == Data("original-aerial".utf8)
    )
}

@Test func wallpaperStoreChangeMonitorDeliversChangedSnapshotBeforeLaterRewrite() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "AuraFlowWallpaperMonitor-\(UUID().uuidString)",
            isDirectory: true
        )
    let storeURL = root.appendingPathComponent("Index.plist")
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    func plistData(_ value: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["value": value],
            format: .binary,
            options: 0
        )
    }

    let initialData = try plistData("initial")
    let changedData = try plistData("downloaded-image")
    let laterData = try plistData("aerial")
    try initialData.write(to: storeURL, options: .atomic)

    let snapshots = WallpaperStoreSnapshotBox()
    let monitor = WallpaperStoreChangeMonitor(
        directoryURL: root,
        storeURL: storeURL,
        callback: { snapshots.append($0) }
    )
    let started = monitor.start()
    #expect(started)
    guard started else { return }
    defer { monitor.stop() }

    // Let the polling timer settle, then rewrite the store again before the
    // directory-event debounce can fire. The callback must retain the image
    // snapshot observed at the first write, not reread the later Aerial data.
    try await Task.sleep(nanoseconds: 100_000_000)
    try changedData.write(to: storeURL, options: .atomic)
    try await Task.sleep(nanoseconds: 65_000_000)
    try laterData.write(to: storeURL, options: .atomic)

    for _ in 0..<20 {
        if snapshots.contains(changedData) { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(snapshots.contains(changedData))
}

private func readWallpaperStore(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try #require(
        PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
    )
}

private func writeWallpaperStore(
    _ root: [String: Any],
    to url: URL
) throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: root,
        format: .binary,
        options: 0
    )
    try data.write(to: url, options: .atomic)
}

private func testImageWallpaperMode(
    url: URL,
    timestamp: Date
) throws -> [String: Any] {
    var mode = AerialLockScreenFixture.makeMode(
        provider: WallpaperPlatformConstants.imageProviderID,
        configuration: [
            "type": "imageFile",
            "url": ["relative": url.absoluteString],
        ]
    )
    mode["LastSet"] = timestamp
    mode["LastUse"] = timestamp
    var content = try #require(mode["Content"] as? [String: Any])
    var choices = try #require(content["Choices"] as? [[String: Any]])
    choices[0]["Files"] = [["relative": url.absoluteString]]
    content["Choices"] = choices
    mode["Content"] = content
    return mode
}

private func testImageWallpaperStoreData(
    url: URL,
    timestamp: Date
) throws -> Data {
    let mode = try testImageWallpaperMode(url: url, timestamp: timestamp)
    let container: [String: Any] = [
        "Type": "individual",
        "Desktop": mode,
    ]
    return try PropertyListSerialization.data(
        fromPropertyList: [
            "AllSpacesAndDisplays": container,
            "SystemDefault": container,
            "Displays": [String: Any](),
            "Spaces": [String: Any](),
        ],
        format: .binary,
        options: 0
    )
}

private func replaceTestDesktopModes(
    in root: [String: Any],
    provider: String
) -> [String: Any] {
    var result = root
    let mode = AerialLockScreenFixture.makeMode(
        provider: provider,
        configuration: [:]
    )
    func replace(_ value: Any) -> Any {
        guard var container = value as? [String: Any] else {
            return value
        }
        if container["Desktop"] != nil {
            container["Desktop"] = mode
        } else if container["Linked"] != nil {
            container["Linked"] = mode
        }
        return container
    }

    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        if let value = result[key] {
            result[key] = replace(value)
        }
    }
    if let displays = result["Displays"] as? [String: Any] {
        result["Displays"] = displays.mapValues(replace)
    }
    if let spaces = result["Spaces"] as? [String: Any] {
        result["Spaces"] = spaces.mapValues { value in
            guard var space = value as? [String: Any] else {
                return value
            }
            if let defaultValue = space["Default"] {
                space["Default"] = replace(defaultValue)
            }
            if let displays = space["Displays"] as? [String: Any] {
                space["Displays"] = displays.mapValues(replace)
            }
            return space
        }
    }
    return result
}

private func testWallpaperContainers(
    in root: [String: Any]
) -> [[String: Any]] {
    var result: [[String: Any]] = []
    func append(_ value: Any?) {
        if let container = value as? [String: Any] {
            result.append(container)
        }
    }
    append(root["AllSpacesAndDisplays"])
    append(root["SystemDefault"])
    if let displays = root["Displays"] as? [String: Any] {
        for value in displays.values { append(value) }
    }
    if let spaces = root["Spaces"] as? [String: Any] {
        for value in spaces.values {
            guard let space = value as? [String: Any] else { continue }
            append(space["Default"])
            if let displays = space["Displays"] as? [String: Any] {
                for display in displays.values { append(display) }
            }
        }
    }
    return result
}

private func replaceTestDesktopModesDistinctly(
    in root: [String: Any]
) -> [String: Any] {
    var result = root
    var revision = 0
    func replace(_ value: Any) -> Any {
        guard var container = value as? [String: Any] else {
            return value
        }
        revision += 1
        let mode = AerialLockScreenFixture.makeMode(
            provider: "com.apple.wallpaper.choice.route-\(revision)",
            configuration: [:]
        )
        if container["Desktop"] != nil {
            container["Desktop"] = mode
        } else if container["Linked"] != nil {
            container["Linked"] = mode
        }
        return container
    }
    for key in ["AllSpacesAndDisplays", "SystemDefault"] {
        if let value = result[key] { result[key] = replace(value) }
    }
    if var displays = result["Displays"] as? [String: Any] {
        for key in displays.keys.sorted() {
            if let value = displays[key] { displays[key] = replace(value) }
        }
        result["Displays"] = displays
    }
    if var spaces = result["Spaces"] as? [String: Any] {
        for spaceID in spaces.keys.sorted() {
            guard var space = spaces[spaceID] as? [String: Any] else {
                continue
            }
            if let value = space["Default"] {
                space["Default"] = replace(value)
            }
            if var displays = space["Displays"] as? [String: Any] {
                for displayID in displays.keys.sorted() {
                    if let value = displays[displayID] {
                        displays[displayID] = replace(value)
                    }
                }
                space["Displays"] = displays
            }
            spaces[spaceID] = space
        }
        result["Spaces"] = spaces
    }
    return result
}

private func testDesktopRouteData(
    in root: [String: Any]
) -> [String: Data] {
    var result: [String: Data] = [:]
    func append(_ path: String, _ value: Any?) {
        guard let container = value as? [String: Any] else { return }
        let key = container["Desktop"] != nil ? "Desktop" : "Linked"
        guard let mode = container[key] as? [String: Any],
              let data = wallpaperModeData(mode)
        else { return }
        result[path + "." + key] = data
    }
    append("AllSpacesAndDisplays", root["AllSpacesAndDisplays"])
    append("SystemDefault", root["SystemDefault"])
    if let displays = root["Displays"] as? [String: Any] {
        for key in displays.keys.sorted() {
            append("Displays.\(key)", displays[key])
        }
    }
    if let spaces = root["Spaces"] as? [String: Any] {
        for spaceID in spaces.keys.sorted() {
            guard let space = spaces[spaceID] as? [String: Any] else {
                continue
            }
            append("Spaces.\(spaceID).Default", space["Default"])
            if let displays = space["Displays"] as? [String: Any] {
                for displayID in displays.keys.sorted() {
                    append(
                        "Spaces.\(spaceID).Displays.\(displayID)",
                        displays[displayID]
                    )
                }
            }
        }
    }
    return result
}

private func wallpaperModeData(_ mode: [String: Any]) -> Data? {
    try? PropertyListSerialization.data(
        fromPropertyList: mode,
        format: .xml,
        options: 0
    )
}

private func wallpaperChoiceProviders(_ value: Any) -> [String] {
    if let dictionary = value as? [String: Any] {
        var providers: [String] = []
        if let provider = dictionary["Provider"] as? String {
            providers.append(provider)
        }
        for nestedValue in dictionary.values {
            providers.append(
                contentsOf: wallpaperChoiceProviders(nestedValue)
            )
        }
        return providers
    }
    if let array = value as? [Any] {
        return array.flatMap(wallpaperChoiceProviders)
    }
    return []
}

private func wallpaperStoreContains(
    _ value: Any,
    provider: String,
    assetID: String?
) -> Bool {
    if let dictionary = value as? [String: Any] {
        if dictionary["Provider"] as? String == provider {
            guard let assetID else { return true }
            guard let data = dictionary["Configuration"] as? Data,
                  let configuration =
                    try? PropertyListSerialization.propertyList(
                        from: data,
                        options: [],
                        format: nil
                    ) as? [String: Any]
            else {
                return false
            }
            return configuration["assetID"] as? String == assetID
        }
        return dictionary.values.contains {
            wallpaperStoreContains(
                $0,
                provider: provider,
                assetID: assetID
            )
        }
    }
    if let array = value as? [Any] {
        return array.contains {
            wallpaperStoreContains(
                $0,
                provider: provider,
                assetID: assetID
            )
        }
    }
    return false
}

private func wallpaperStoreText(_ value: Any) -> String {
    if let string = value as? String {
        return string
    }
    if let data = value as? Data,
       let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
       ) {
        return wallpaperStoreText(propertyList)
    }
    if let dictionary = value as? [String: Any] {
        return dictionary
            .map { wallpaperStoreText($0.key) + wallpaperStoreText($0.value) }
            .joined(separator: " ")
    }
    if let array = value as? [Any] {
        return array.map(wallpaperStoreText).joined(separator: " ")
    }
    return String(describing: value)
}
