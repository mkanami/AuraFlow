import AuraTerminalWallpaperCore
@testable import AuraTerminalWallpaperAgent
import AppKit
import CoreText
import Foundation
import ImageIO
import Testing

@Test func terminalLockScreenHeartbeatExpiresAndStaysInTerminalNamespace() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraTerminalLockFrame-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TerminalWallpaperRuntimeStore(
        appSupportURL: root.appendingPathComponent("terminal-wallpaper", isDirectory: true),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/terminal.plist")
    )
    let heartbeat = TerminalLockScreenHeartbeat(pid: 42, updatedAt: 100)
    try store.saveLockScreenHeartbeat(heartbeat)
    #expect(store.loadLockScreenHeartbeat() == heartbeat)
    #expect(heartbeat.isFresh(at: 105))
    #expect(!heartbeat.isFresh(at: 107))
    #expect(!heartbeat.isFresh(at: 99))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("config.json").path))
    store.removeLockScreenPublication()
    #expect(store.loadLockScreenHeartbeat() == nil)
}

@Test func terminalLockScreenFrameEncodesRasterizedPixels() {
    let pixels = Data([
        0, 0, 255, 255, 0, 255, 0, 255,
        255, 0, 0, 255, 255, 255, 255, 255,
    ])
    let png = TerminalLockScreenFramePublisher.encodePNG(pixels, width: 2, height: 2)
    #expect(png != nil)
    guard let png,
          let source = CGImageSourceCreateWithData(png as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
    #expect(image.width == 2)
    #expect(image.height == 2)
}

@Test @MainActor func terminalLockScreenPublisherWritesOnlyWhileLocked() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraTerminalLockPublisher-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TerminalWallpaperRuntimeStore(
        appSupportURL: root.appendingPathComponent("terminal-wallpaper", isDirectory: true),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/terminal.plist")
    )
    let publisher = TerminalLockScreenFramePublisher(store: store)
    let pixel = Data([0, 0, 0, 255])

    publisher.publish(pixel, width: 1, height: 1)
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(!FileManager.default.fileExists(atPath: store.lockScreenFrameURL.path))

    publisher.setLockScreenActive(true)
    publisher.publish(pixel, width: 1, height: 1)
    let deadline = Date().addingTimeInterval(2)
    while !FileManager.default.fileExists(atPath: store.lockScreenFrameURL.path), Date() < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(FileManager.default.fileExists(atPath: store.lockScreenFrameURL.path))
    publisher.revoke()
}

@Test func terminalPTYSessionSpawnsDirectChildAndResizes() throws {
    let session = TerminalPTYSession()
    let outputLock = NSLock()
    var output = Data()
    let command = TerminalCommandConfiguration(
        executable: "/bin/sh",
        arguments: [
            "-c",
            "printf '%s' \"$TERM:$COLORTERM:$COLUMNS:$LINES\"; sleep 5"
        ]
    )

    let childPID = try session.start(
        command: command,
        columns: 153,
        rows: 48,
        onData: { data in
            outputLock.lock()
            output.append(data)
            outputLock.unlock()
        },
        onExit: { _ in }
    )
    defer { session.stop() }

    #expect(childPID > 0)
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        outputLock.lock()
        let text = String(decoding: output, as: UTF8.self)
        outputLock.unlock()
        if text.contains("xterm-256color:truecolor:153:48") { break }
        Thread.sleep(forTimeInterval: 0.02)
    }

    outputLock.lock()
    let text = String(decoding: output, as: UTF8.self)
    outputLock.unlock()
    #expect(text.contains("xterm-256color:truecolor:153:48"))
    try session.resize(columns: 120, rows: 40)
    #expect(session.childPID == childPID)

    session.stop()
    #expect(session.childPID == nil)
    #expect(session.masterFileDescriptor == nil)
}

@Test func terminalPTYSessionPausesAndResumesItsChild() throws {
    let session = TerminalPTYSession()
    let outputLock = NSLock()
    var output = Data()
    let command = TerminalCommandConfiguration(
        executable: "/bin/sh",
        arguments: ["-c", "while :; do printf x; sleep 0.02; done"]
    )
    _ = try session.start(
        command: command,
        columns: 80,
        rows: 24,
        onData: { data in
            outputLock.lock()
            output.append(data)
            outputLock.unlock()
        },
        onExit: { _ in }
    )
    defer { session.stop() }

    let outputDeadline = Date().addingTimeInterval(2)
    while Date() < outputDeadline {
        outputLock.lock()
        let count = output.count
        outputLock.unlock()
        if count >= 4 { break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    outputLock.lock()
    let initialCount = output.count
    outputLock.unlock()
    #expect(initialCount >= 4)

    try session.setPaused(true)
    #expect(session.isPaused)
    Thread.sleep(forTimeInterval: 0.1)
    outputLock.lock()
    let pausedCount = output.count
    outputLock.unlock()
    Thread.sleep(forTimeInterval: 0.15)
    outputLock.lock()
    let stillPausedCount = output.count
    outputLock.unlock()
    #expect(stillPausedCount == pausedCount)

    try session.setPaused(false)
    #expect(!session.isPaused)
    let resumeDeadline = Date().addingTimeInterval(1)
    while Date() < resumeDeadline {
        outputLock.lock()
        let count = output.count
        outputLock.unlock()
        if count > pausedCount { break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    outputLock.lock()
    let resumedCount = output.count
    outputLock.unlock()
    #expect(resumedCount > pausedCount)
}

@Test func terminalConfigNormalizesToSafeBounds() {
    #expect(TerminalRenderConfiguration().maxFPS == 30)
    let config = TerminalWallpaperConfig(
        command: TerminalCommandConfiguration(executable: "  /usr/bin/top  "),
        render: TerminalRenderConfiguration(
            fixedWidth: 1,
            fixedHeight: 100_000,
            columns: 0,
            rows: 10_000,
            fontFamily: " ",
            fontSize: 200,
            cellSpacing: -1,
            maxFPS: 500,
            backgroundOpacity: 2,
            textScale: 100
        )
    ).normalized()

    #expect(config.schemaVersion == 1)
    #expect(config.command.executable == "/usr/bin/top")
    #expect(config.render.fixedWidth == 320)
    #expect(config.render.fixedHeight == 16_384)
    #expect(config.render.columns == 1)
    #expect(config.render.rows == 500)
    #expect(config.render.fontFamily == "System Monospace")
    #expect(config.render.fontSize == 96)
    #expect(config.render.cellSpacing == 0)
    #expect(config.render.maxFPS == 60)
    #expect(config.render.textScale == 3)
    #expect(config.render.backgroundOpacity == 1)
}

@Test func terminalConfigRoundTripsSchemaAndSnakeCaseKeys() throws {
    let config = TerminalWallpaperConfig(
        command: TerminalCommandConfiguration(
            catalogItemID: "top",
            executable: "/bin/echo",
            arguments: ["hello"]
        )
    )
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let data = try encoder.encode(config)
    let json = String(decoding: data, as: UTF8.self)
    let restored = try decoder.decode(TerminalWallpaperConfig.self, from: data)

    #expect(json.contains("schema_version"))
    #expect(restored == config)

    let legacyRender = try decoder.decode(
        TerminalRenderConfiguration.self,
        from: Data("{}".utf8)
    )
    #expect(legacyRender.textScale == 1.5)
    let legacyBehavior = try decoder.decode(TerminalWallpaperBehavior.self, from: Data("{}".utf8))
    #expect(legacyBehavior.pauseOnFullscreen)
}

@Test func terminalCatalogSeparatesAppsAndUtilities() {
    #expect(TerminalWallpaperCatalog.item(id: "asciiquarium")?.title == "Asciiquarium")
    #expect(TerminalWallpaperCatalog.item(id: "cmatrix")?.title == "CMatrix")
    #expect(TerminalWallpaperCatalog.item(id: "pipes")?.title == "Pipes")
    #expect(TerminalWallpaperCatalog.item(id: "btop")?.category == .applications)
    #expect(TerminalWallpaperCatalog.item(id: "top")?.category == .utilities)
    #expect(TerminalWallpaperCatalog.item(id: "top")?.resolvedExecutable() == "/usr/bin/top")
    #expect(
        TerminalWallpaperCatalog.availableItems().contains {
            $0.id == "top" && $0.category == .utilities
        }
    )
}

@Test func terminalCatalogSearchToleratesOneTypo() {
    let lavat = TerminalWallpaperCatalogItem(
        id: "lavat",
        title: "lavat",
        subtitle: "Terminal lava lamp",
        category: .applications,
        systemImage: "terminal",
        executableCandidates: ["/opt/homebrew/bin/lavat"]
    )

    #expect(TerminalWallpaperCatalog.matchesSearch(query: "lavac", item: lavat))
    #expect(!TerminalWallpaperCatalog.matchesSearch(query: "homebrew", item: lavat, includeExecutablePaths: false))
    #expect(!TerminalWallpaperCatalog.matchesSearch(query: "zzzzz", item: lavat))
    #expect(
        TerminalWallpaperCatalog.searchItems(for: "lavac", candidates: [lavat])
            .first?.id == "lavat"
    )
}

@Test func terminalCatalogKeepsExecutableSymlinksInDiscovery() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("auraflow-terminal-bin-\(UUID().uuidString)")
    let bin = root.appendingPathComponent("bin")
    let source = root.appendingPathComponent("source-terminal")
    let link = bin.appendingPathComponent("linked-terminal")
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try "#!/bin/sh\nprintf ok\n".write(to: source, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
    try FileManager.default.createSymbolicLink(
        at: link,
        withDestinationURL: source
    )

    let discovered = TerminalWallpaperCatalog.discoveredItems(
        environment: ["PATH": bin.path]
    )

    #expect(
        discovered.contains {
            $0.title == "linked-terminal" &&
            $0.executableCandidates.first == link.standardizedFileURL.path
        }
    )
    #expect(
        TerminalWallpaperCatalog.exactExecutableItems(
            named: "linked-terminal", environment: ["PATH": bin.path]
        ).first?.title == "linked-terminal"
    )
    #expect(TerminalWallpaperCatalog.exactExecutableItems(named: "linked-terminal-not-present", environment: ["PATH": bin.path]).isEmpty)
    #expect(TerminalWallpaperCatalog.exactExecutableItems(named: "../linked-terminal", environment: ["PATH": bin.path]).isEmpty)
}

@Test func terminalCatalogRanksLavaLampAheadOfNearMatchesWhenInstalled() {
    guard TerminalExecutableLocator.resolve("lavat") != nil else { return }

    let results = TerminalWallpaperCatalog.searchItems(for: "lavac")
    #expect(results.first?.id == "lavat")
}

@Test func terminalCatalogCanResolveDiscoveredMacExecutables() {
    let discovered = TerminalWallpaperCatalog.item(id: "discovered:/bin/sh")
    #expect(discovered?.title == "sh")
    #expect(discovered?.category == .utilities)
    #expect(discovered?.resolvedExecutable() == "/bin/sh")
}

@Test func terminalExecutableLocatorFindsPathAndNamedExecutables() throws {
    #expect(TerminalExecutableLocator.resolve("sh", environment: ["PATH": "/bin"]) == "/bin/sh")
    #expect(TerminalExecutableLocator.resolve("/bin/sh") == "/bin/sh")
    #expect(TerminalExecutableLocator.resolve("definitely-not-a-terminal-program", environment: ["PATH": "/bin"]) == nil)

    let temporaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("auraflow-terminal-executable-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    try "#!/bin/sh\nprintf ok\n".write(to: temporaryURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporaryURL.path)
    #expect(TerminalExecutableLocator.resolve(temporaryURL.path) == temporaryURL.path)

    let appURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowTerminalApp-\(UUID().uuidString).app")
    let appExecutableURL = appURL.appendingPathComponent("Contents/MacOS/DemoTerminal")
    try FileManager.default.createDirectory(
        at: appExecutableURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let info: [String: Any] = [
        "CFBundleExecutable": "DemoTerminal",
        "CFBundleIdentifier": "com.example.auraflow-test-terminal",
        "CFBundlePackageType": "APPL",
    ]
    let infoData = try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .xml,
        options: 0
    )
    try infoData.write(to: appURL.appendingPathComponent("Contents/Info.plist"))
    try "#!/bin/sh\nprintf app\n".write(to: appExecutableURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appExecutableURL.path)
    defer { try? FileManager.default.removeItem(at: appURL) }
    #expect(TerminalExecutableLocator.resolve(appURL.path) == appExecutableURL.path)
}

@Test func terminalRenderGeometrySupportsResolutionAndScaleModes() {
    let native = TerminalRenderGeometry.pixelSize(
        configuration: TerminalRenderConfiguration(pixelMode: .native),
        drawableWidth: 2560,
        drawableHeight: 1440
    )
    #expect(native == TerminalPixelSize(width: 2560, height: 1440))

    let fixed = TerminalRenderGeometry.pixelSize(
        configuration: TerminalRenderConfiguration(
            pixelMode: .fixed,
            fixedWidth: 1920,
            fixedHeight: 1080
        ),
        drawableWidth: 2560,
        drawableHeight: 1440
    )
    #expect(fixed == TerminalPixelSize(width: 1920, height: 1080))

    #expect(
        TerminalRenderGeometry.scaleFactors(
            contentWidth: 100,
            contentHeight: 50,
            targetWidth: 200,
            targetHeight: 200,
            mode: .fit
        ) == TerminalScaleFactors(x: 2, y: 2)
    )
    #expect(
        TerminalRenderGeometry.scaleFactors(
            contentWidth: 100,
            contentHeight: 50,
            targetWidth: 200,
            targetHeight: 200,
            mode: .fill
        ) == TerminalScaleFactors(x: 4, y: 4)
    )
    #expect(
        TerminalRenderGeometry.scaleFactors(
            contentWidth: 100,
            contentHeight: 50,
            targetWidth: 200,
            targetHeight: 200,
            mode: .stretch
        ) == TerminalScaleFactors(x: 2, y: 4)
    )

    for target in [(width: 2560.0, height: 1080.0), (width: 1200.0, height: 1920.0)] {
        let contentWidth = 1600.0
        let contentHeight = 900.0
        let scale = TerminalRenderGeometry.scaleFactors(
            contentWidth: contentWidth,
            contentHeight: contentHeight,
            targetWidth: target.width,
            targetHeight: target.height,
            mode: .fit
        )
        let drawnWidth = contentWidth * scale.x
        let drawnHeight = contentHeight * scale.y
        let offsetX = (target.width - drawnWidth) / 2
        let offsetY = (target.height - drawnHeight) / 2

        #expect(offsetX >= 0)
        #expect(offsetY >= 0)
        #expect(drawnWidth <= target.width)
        #expect(drawnHeight <= target.height)
        #expect(abs(offsetX * 2 + drawnWidth - target.width) < 0.001)
        #expect(abs(offsetY * 2 + drawnHeight - target.height) < 0.001)
    }
}

@Test func terminalAutomaticGridUsesCoreTextCellMetrics() {
    let configuration = TerminalRenderConfiguration(
        fontSize: 18,
        cellSpacing: 2,
        textScale: 1
    )
    let metrics = TerminalFontMetrics.cellMetrics(for: configuration)
    let noSpacingMetrics = TerminalFontMetrics.cellMetrics(
        family: configuration.fontFamily,
        pointSize: configuration.effectiveFontSize
    )
    let grid = TerminalRenderGeometry.automaticGrid(
        logicalWidth: 1440,
        logicalHeight: 900,
        cellWidth: metrics.width,
        lineHeight: metrics.height
    )

    #expect(metrics.width > 0)
    #expect(metrics.height > 0)
    #expect(abs(metrics.width - noSpacingMetrics.width - 2) < 0.01)
    #expect(abs(metrics.height - noSpacingMetrics.height - 2) < 0.01)
    #expect(grid.columns == Int(1440 / metrics.width))
    #expect(grid.rows == Int(900 / metrics.height))
    #expect(
        TerminalRenderGeometry.pixelScaleFactor(
            pixelWidth: 2880,
            pixelHeight: 1800,
            logicalWidth: 1440,
            logicalHeight: 900
        ) == 2
    )
    #expect(
        TerminalRenderGeometry.pixelScaleFactor(
            pixelWidth: 1920,
            pixelHeight: 1080,
            logicalWidth: 1440,
            logicalHeight: 900
        ) == 1.2
    )
}

@Test func terminalSystemMonospaceMatchesMacOSMonospacedFontAndHonorsBold() {
    let family = TerminalFontResolver.systemMonospaceFamily
    let regular = TerminalFontResolver.font(family: family, size: 18)
    let expectedRegular = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
    #expect(CTFontCopyPostScriptName(regular) as String == expectedRegular.fontName)

    let bold = TerminalFontResolver.font(family: family, size: 18, bold: true)
    let expectedBold = NSFont.monospacedSystemFont(ofSize: 18, weight: .bold)
    #expect(CTFontCopyPostScriptName(bold) as String == expectedBold.fontName)
    #expect(CTFontGetSymbolicTraits(bold).contains(.traitBold))

    let kittyAlias = TerminalFontResolver.font(family: "monospace", size: 18)
    #expect(CTFontCopyPostScriptName(kittyAlias) as String == expectedRegular.fontName)
}

@Test func terminalIndexedColorsUseKittyAnsiAndXterm256Mappings() {
    let palette = TerminalPalette.kittyDefault16
    let fallback = TerminalRGBA(red: 0.25, green: 0.25, blue: 0.25)

    #expect(TerminalColor.indexed(6).resolved(defaultColor: fallback, palette: palette) == palette[6])
    #expect(palette[6] == TerminalRGBA(red: 13.0 / 255, green: 205.0 / 255, blue: 205.0 / 255))
    #expect(TerminalColor.indexed(16).resolved(defaultColor: fallback, palette: palette) == .black)
    #expect(
        TerminalColor.indexed(196).resolved(defaultColor: fallback, palette: palette)
            == TerminalRGBA(red: 1, green: 0, blue: 0)
    )
    #expect(
        TerminalColor.indexed(232).resolved(defaultColor: fallback, palette: palette)
            == TerminalRGBA(red: 8.0 / 255, green: 8.0 / 255, blue: 8.0 / 255)
    )
    #expect(
        TerminalColor.indexed(255).resolved(defaultColor: fallback, palette: palette)
            == TerminalRGBA(red: 238.0 / 255, green: 238.0 / 255, blue: 238.0 / 255)
    )
}

@Test func terminalFitLayoutAppliesTextScaleOnceAndKeepsFixedGridInFrame() {
    let scaledConfiguration = TerminalRenderConfiguration(
        columns: 153,
        rows: 48,
        fontSize: 12,
        scaleMode: .fit,
        textScale: 1.5
    )
    let metrics = TerminalFontMetrics.cellMetrics(for: scaledConfiguration)
    let unscaledMetrics = TerminalFontMetrics.cellMetrics(
        family: scaledConfiguration.fontFamily,
        pointSize: scaledConfiguration.fontSize
    )
    #expect(abs(metrics.width - unscaledMetrics.width * 1.5) < 0.01)
    #expect(abs(metrics.height - unscaledMetrics.height * 1.5) < 0.01)

    for target in [(width: 3420.0, height: 2224.0), (width: 1200.0, height: 1920.0)] {
        let layout = TerminalRenderGeometry.layout(
            columns: 153,
            rows: 48,
            cellWidth: metrics.width,
            lineHeight: metrics.height,
            targetWidth: target.width,
            targetHeight: target.height,
            mode: .fit
        )
        #expect(layout.offsetX >= -0.001)
        #expect(layout.offsetY >= -0.001)
        #expect(layout.drawnWidth <= target.width + 0.001)
        #expect(layout.drawnHeight <= target.height + 0.001)
        let horizontalCenterError = abs((layout.offsetX * 2) + layout.drawnWidth - target.width)
        let verticalCenterError = abs((layout.offsetY * 2) + layout.drawnHeight - target.height)
        #expect(horizontalCenterError < 0.001)
        #expect(verticalCenterError < 0.001)
    }
}

@Test func terminalGridSnapshotsExposeDirtyRevisions() {
    var grid = TerminalGrid(columns: 4, rows: 1)
    let initial = grid.snapshot()
    grid.put("A")
    let changed = grid.snapshot()
    let unchanged = grid.snapshot()

    #expect(changed.revision > initial.revision)
    #expect(unchanged.revision == changed.revision)
}

@Test func vtParserHandlesChunkedUtf8AndAnsiStyles() {
    var parser = VTParser(columns: 12, rows: 3)
    parser.feed(Data([0x48, 0x69, 0x20, 0xF0]))
    parser.feed(Data([0x9F, 0x98, 0x80, 0x20, 0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x52, 0x1B, 0x5B, 0x30, 0x6D]))

    let snapshot = parser.grid.snapshot()
    #expect(snapshot.cell(column: 0, row: 0).text == "H")
    #expect(snapshot.cell(column: 1, row: 0).text == "i")
    #expect(snapshot.cell(column: 3, row: 0).text == "😀")
    #expect(snapshot.cell(column: 6, row: 0).text == "R")
    #expect(snapshot.cell(column: 6, row: 0).style.foreground == .indexed(1))
}

@Test func vtParserSupportsCursorEraseAndAlternateScreen() {
    var parser = VTParser(columns: 8, rows: 2)
    parser.feed(Data("abc\u{1B}[2J\u{1B}[2;3HZ\u{1B}[?1049hALT\u{1B}[?1049l".utf8))

    let snapshot = parser.grid.snapshot()
    #expect(snapshot.cell(column: 0, row: 0).text == " ")
    #expect(snapshot.cell(column: 2, row: 1).text == "Z")
    #expect(snapshot.cell(column: 0, row: 0).text != "A")
}

@Test func terminalGridScrollsInsideConfiguredRegion() {
    var parser = VTParser(columns: 5, rows: 2)
    parser.feed(Data("one\r\ntwo\r\nthree".utf8))

    let snapshot = parser.grid.snapshot()
    #expect(snapshot.cell(column: 0, row: 0).text == "t")
    #expect(snapshot.cell(column: 0, row: 1).text == "t")
}

@Test func terminalGridRecognizesWideAndCombiningCharacters() {
    var grid = TerminalGrid(columns: 6, rows: 1)
    grid.put("界")
    grid.put("e")
    grid.put("\u{301}")

    let snapshot = grid.snapshot()
    #expect(snapshot.cell(column: 0, row: 0).width == 2)
    #expect(snapshot.cell(column: 2, row: 0).text == "e\u{301}")
}

@Test func vtParserWrapsAfterTheLastColumn() {
    var parser = VTParser(columns: 3, rows: 2)
    parser.feed(Data("abcd".utf8))

    let snapshot = parser.grid.snapshot()
    #expect(snapshot.cell(column: 0, row: 0).text == "a")
    #expect(snapshot.cell(column: 2, row: 0).text == "c")
    #expect(snapshot.cell(column: 0, row: 1).text == "d")
}

@Test func vtParserAppliesChunkedCursesDeleteAndEraseCommands() {
    var parser = VTParser(columns: 10, rows: 2)
    // ncurses uses DCH to remove a moving sprite's old cells and ECH for
    // remaining fragments. Split every byte as a PTY may do under load.
    let output = "ABCDEFGH\u{1B}[1;3H\u{1B}[2P\u{1B}[1;3H\u{1B}[2X"
    for byte in output.utf8 { parser.feed(Data([byte])) }

    let row = (0..<10).map { parser.grid.snapshot().cell(column: $0, row: 0).text }.joined()
    #expect(row == "AB  GH    ")
    #expect(parser.grid.cursorColumn == 2)
}

@Test func vtParserSupportsInsertDeleteAndScrollingWithinMargins() {
    var parser = VTParser(columns: 5, rows: 4)
    parser.feed(Data("\u{1B}[1;1HAAAAA\u{1B}[2;1HBBBBB\u{1B}[3;1HCCCCC\u{1B}[4;1HDDDDD".utf8))
    parser.feed(Data("\u{1B}[2;3r\u{1B}[4;1HZ\u{1B}[2;1H\u{1B}M".utf8))

    var snapshot = parser.grid.snapshot()
    #expect(snapshot.cell(column: 0, row: 0).text == "A")
    #expect(snapshot.cell(column: 0, row: 1).text == " ")
    #expect(snapshot.cell(column: 0, row: 2).text == "B")
    #expect(snapshot.cell(column: 0, row: 3).text == "Z")

    parser.feed(Data("\u{1B}[r\u{1B}[4;1H\u{1B}[1L\u{1B}[2;1H\u{1B}[1M".utf8))
    snapshot = parser.grid.snapshot()
    #expect(snapshot.cell(column: 0, row: 0).text == "A")
    #expect(snapshot.cell(column: 0, row: 1).text == "B")
    #expect(snapshot.cell(column: 0, row: 2).text == " ")
    #expect(snapshot.cell(column: 0, row: 3).text == " ")
}

@Test func vtParserInsertsCharactersAndRespectsOriginAndWrapModes() {
    var parser = VTParser(columns: 5, rows: 4)
    parser.feed(Data("ABCDE\u{1B}[1;3H\u{1B}[2@".utf8))
    let firstRow = (0..<5).map { parser.grid.snapshot().cell(column: $0, row: 0).text }.joined()
    #expect(firstRow == "AB  C")

    parser.feed(Data("\u{1B}[2;3r\u{1B}[?6h\u{1B}[1;1HZ\u{1B}[?6l\u{1B}[?7l\u{1B}[4;5HQW".utf8))
    let snapshot = parser.grid.snapshot()
    #expect(snapshot.cell(column: 0, row: 1).text == "Z")
    #expect(snapshot.cell(column: 4, row: 3).text == "W")
    #expect(snapshot.cell(column: 0, row: 3).text == " ")
}

@Test func vtParserScrollsOnlyTheSelectedRegion() {
    var parser = VTParser(columns: 3, rows: 4)
    parser.feed(Data("\u{1B}[1;1HAAA\u{1B}[2;1HBBB\u{1B}[3;1HCCC\u{1B}[4;1HDDD".utf8))
    parser.feed(Data("\u{1B}[2;3r\u{1B}[1S".utf8))
    var snapshot = parser.grid.snapshot()
    #expect(snapshot.cell(column: 0, row: 0).text == "A")
    #expect(snapshot.cell(column: 0, row: 1).text == "C")
    #expect(snapshot.cell(column: 0, row: 2).text == " ")
    #expect(snapshot.cell(column: 0, row: 3).text == "D")

    parser.feed(Data("\u{1B}[1T".utf8))
    snapshot = parser.grid.snapshot()
    #expect(snapshot.cell(column: 0, row: 0).text == "A")
    #expect(snapshot.cell(column: 0, row: 1).text == " ")
    #expect(snapshot.cell(column: 0, row: 2).text == "C")
    #expect(snapshot.cell(column: 0, row: 3).text == "D")
}
