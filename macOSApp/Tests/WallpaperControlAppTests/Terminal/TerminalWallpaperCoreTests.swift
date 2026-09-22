import AuraTerminalWallpaperCore
import Foundation
import Testing

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

    #expect(childPID > 0)
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        outputLock.lock()
        let text = String(decoding: output, as: UTF8.self)
        outputLock.unlock()
        if text.contains("xterm-256color:truecolor:80:24") { break }
        Thread.sleep(forTimeInterval: 0.02)
    }

    outputLock.lock()
    let text = String(decoding: output, as: UTF8.self)
    outputLock.unlock()
    #expect(text.contains("xterm-256color:truecolor:80:24"))
    try session.resize(columns: 120, rows: 40)
    #expect(session.childPID == childPID)

    session.stop()
    #expect(session.childPID == nil)
    #expect(session.masterFileDescriptor == nil)
}

@Test func terminalConfigNormalizesToSafeBounds() {
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
    #expect(config.render.fontFamily == "Menlo")
    #expect(config.render.fontSize == 96)
    #expect(config.render.cellSpacing == 0)
    #expect(config.render.maxFPS == 120)
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
}

@Test func terminalCatalogSeparatesAppsAndUtilities() {
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
    #expect(!TerminalWallpaperCatalog.matchesSearch(query: "zzzzz", item: lavat))
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
}

@Test func terminalAutomaticGridUsesTerminalPointsAndScalesGlyphsForPixels() {
    let fontSize = TerminalRenderConfiguration(fontSize: 14, textScale: 1.5).effectiveFontSize
    let grid = TerminalRenderGeometry.automaticGrid(
        logicalWidth: 1440,
        logicalHeight: 900,
        fontSize: fontSize
    )

    #expect(fontSize == 21)
    #expect(grid.columns == 110)
    #expect(grid.rows == 34)
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
