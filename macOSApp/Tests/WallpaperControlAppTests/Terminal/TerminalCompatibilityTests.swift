import AppKit
@testable import AuraTerminalWallpaperCore
@testable import AuraTerminalRendering
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers

@Test func terminalEnvironmentRepairsFinderPathAndByteLocale() {
    let environment = TerminalProcessEnvironment.make(
        inherited: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"],
        overrides: [:], executable: "/opt/homebrew/bin/pipes.sh", columns: 80, rows: 24
    )
    #expect(environment["PATH"]?.hasPrefix("/opt/homebrew/bin:/usr/local/bin:") == true)
    #expect(environment["LC_ALL"] == "en_US.UTF-8")
    #expect(environment["TERM"] == "xterm-256color")
    let overrides = ["PATH": "/custom/bin:/bin", "LC_ALL": "de_DE.UTF-8"]
    let custom = TerminalProcessEnvironment.make(
        inherited: [:], overrides: overrides, executable: "/tmp/script", columns: 80, rows: 24
    )
    #expect(custom["PATH"] == overrides["PATH"])
    #expect(custom["LC_ALL"] == overrides["LC_ALL"])
}

@Test func terminalBlocksCoverTheCellAndPreserveComplementaryHalves() {
    let atlas = CoreTextGlyphAtlas(atlasSize: 512)
    for (width, height) in [(13, 25), (22, 42), (9, 17)] {
        let full = atlas.rasterizeForTesting(text: "█", cellWidth: width, cellHeight: height).pixels
        let upper = atlas.rasterizeForTesting(text: "▀", cellWidth: width, cellHeight: height).pixels
        let lower = atlas.rasterizeForTesting(text: "▄", cellWidth: width, cellHeight: height).pixels
        #expect(full.allSatisfy { $0 == 255 })
        for index in 0..<full.count {
            #expect(Int(upper[index]) + Int(lower[index]) == 255)
        }
    }
}

@Test func terminalRendererInvalidationReuploadsUnpresentedGlyphsAndCells() {
    let atlas = CoreTextGlyphAtlas(atlasSize: 512)
    var parser = VTParser(columns: 8, rows: 3)
    parser.feed(Data("\u{1b}[31mA█界".utf8))
    let configuration = TerminalRenderConfiguration(fontSize: 12, textScale: 1)
    let discarded = atlas.prepare(snapshot: parser.grid.snapshot(), configuration: configuration,
                                  width: 160, height: 90, fontPixelScale: 1)
    atlas.invalidate()
    let replacement = atlas.prepare(snapshot: parser.grid.snapshot(), configuration: configuration,
                                    width: 160, height: 90, fontPixelScale: 1)
    #expect(replacement.fullInstances != nil)
    #expect(replacement.atlasGeneration > discarded.atlasGeneration)
    #expect(replacement.atlasUpdates.count == discarded.atlasUpdates.count)
}

private final class TerminalOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(data) }
    func read() -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
}

// Optional installed-program integration tests: each uses its own short-lived
// PTY; never touches the user's running wallpaper, preferences or processes.
@Test(arguments: ["lavat", "pipes", "cmatrix", "asciiquarium"])
@MainActor func terminalInstalledProgramsProduceRenderableUTF8(_ id: String) async throws {
    let item = try #require(TerminalWallpaperCatalog.item(id: id))
    guard item.resolvedExecutable() != nil else { return }
    let session = TerminalPTYSession(environment: [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C",
        "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
    ])
    let capture = TerminalOutputCapture()
    let command = id == "pipes"
        ? TerminalCommandConfiguration(executable: "pipes.sh")
        : item.commandConfiguration()
    try session.start(command: command, columns: 80, rows: 24,
                      onData: { capture.append($0) }, onExit: { _ in })
    defer { session.stop() }
    let descriptor = try #require(session.masterFileDescriptor)
    #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
    try await Task.sleep(nanoseconds: 1_000_000_000)
    let data = capture.read()
    #expect(!data.isEmpty)
    #expect(!String(decoding: data, as: UTF8.self).contains("\\e["))
    var parser = VTParser(columns: 80, rows: 24)
    // Split at every byte to exercise escape and UTF-8 boundaries.
    for byte in data { parser.feed(Data([byte])) }
    let snapshot = parser.grid.snapshot()
    #expect(snapshot.cells.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
    #expect(!snapshot.cells.contains { $0.text.contains("�") })
    if id == "pipes" {
        #expect(snapshot.cells.contains { cell in
            cell.text.unicodeScalars.contains { (0x2500...0x257F).contains($0.value) }
                && cell.style.foreground != .default
        })
    }
    if let directory = ProcessInfo.processInfo.environment["AURAFLOW_TERMINAL_RENDER_ARTIFACTS"] {
        let frame = try await terminalGPUFrame(snapshot, width: 800, height: 480)
        try saveTerminalFrame(frame, name: id, directory: directory)
    }
}

@MainActor
func terminalGPUFrame(
    _ snapshot: TerminalGridSnapshot,
    width: Int,
    height: Int,
    precedingSnapshots: [TerminalGridSnapshot] = [],
    render: TerminalRenderConfiguration = .init(fontSize: 18, textScale: 1)
) async throws -> (Data, Int, Int) {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: width, height: height),
                                 logicalSize: CGSize(width: width, height: height), device: device)
    view.autoResizeDrawable = false
    view.drawableSize = CGSize(width: width, height: height)
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { view.setRendererPaused(true); window.close() }
    var result: (Data, Int, Int)?
    view.onLockScreenFrame = { [weak view] data, width, height in
        guard view?.displayedRevision == snapshot.revision else { return }
        result = (data, width, height)
    }
    view.setLockScreenCaptureEnabled(true)
    for preceding in precedingSnapshots {
        view.update(snapshot: preceding, configuration: render)
    }
    view.update(snapshot: snapshot, configuration: render)
    let deadline = Date().addingTimeInterval(4)
    while result == nil, Date() < deadline {
        view.draw(view.bounds)
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    return try #require(result)
}

func saveTerminalFrame(_ frame: (Data, Int, Int), name: String, directory: String) throws {
    let (data, width, height) = frame
    let provider = try #require(CGDataProvider(data: data as CFData))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
                                    bitsPerPixel: 32, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = try #require(CGImageDestinationCreateWithURL(root.appendingPathComponent(name + ".png") as CFURL,
                                                                   UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

@Test @MainActor func terminalGPUBlockGridHasNoInternalSeamsAtFractionalScale() async throws {
    var grid = TerminalGrid(columns: 16, rows: 8)
    for _ in 0..<128 { grid.put("█") }
    let (pixels, width, height) = try await terminalGPUFrame(grid.snapshot(), width: 437, height: 271)
    // The central half is inside the Fit content on either axis. No row or
    // column seam may cut through an otherwise fully filled block grid.
    var darkest: UInt8 = 255
    for y in (height / 4)..<(height * 3 / 4) {
        for x in (width / 4)..<(width * 3 / 4) {
            darkest = min(darkest, pixels[(y * width + x) * 4])
        }
    }
    #expect(darkest > 180)
}

@Test(arguments: [(437, 271), (640, 360), (360, 640)]) @MainActor
func terminalGPUSourceCanvasHasNoUnpaintedRemainder(width: Int, height: Int) async throws {
    var grid = TerminalGrid(columns: 153, rows: 48)
    grid.setStyle(.init(background: .rgb(255, 0, 255)))
    for _ in 0..<(153 * 48) { grid.put(" ") }
    grid.setCursorVisible(false)
    // The entire canvas uses the configured terminal background, including
    // sub-cell remainder. It is not a black letterbox around a cropped grid.
    let render = TerminalRenderConfiguration(fontSize: 18, background: .init(red: 1, green: 0, blue: 1), textScale: 1)
    let (pixels, actualWidth, actualHeight) = try await terminalGPUFrame(grid.snapshot(), width: width, height: height, render: render)
    #expect(actualWidth > 0 && actualHeight > 0)
    // Every edge pixel must come from the rendered grid, not black letterbox.
    for y in 0..<actualHeight {
        for x in 0..<actualWidth where y == 0 || y == actualHeight - 1 || x == 0 || x == actualWidth - 1 {
            let index = (y * actualWidth + x) * 4
            #expect(pixels[index] > 240 && pixels[index + 2] > 240)
        }
    }
}

@Test @MainActor func terminalGPUCoalescedUpdatesMatchAFreshCompleteFrame() async throws {
    var parser = VTParser(columns: 20, rows: 8)
    var history: [TerminalGridSnapshot] = []
    for row in 1...8 {
        parser.feed(Data("\u{1b}[\(row);1H\u{1b}[\(30 + row)mA~^/界█▀▄┃╭╮".utf8))
        history.append(parser.grid.snapshot())
    }
    // Include both character deletion and new glyphs while preparation is busy.
    parser.feed(Data("\u{1b}[2;1H\u{1b}[3P\u{1b}[4;5HZ\u{1b}[6;1H\u{1b}[2K".utf8))
    let final = parser.grid.snapshot()
    let fresh = try await terminalGPUFrame(final, width: 640, height: 320)
    let coalesced = try await terminalGPUFrame(final, width: 640, height: 320, precedingSnapshots: history)
    #expect(fresh.0 == coalesced.0)
}

@Test(arguments: [(640, 360), (360, 640), (760, 480)]) @MainActor
func terminalGPUSourceCanvasRetainsEveryCorner(width: Int, height: Int) async throws {
    let render = TerminalRenderConfiguration(columns: 153, rows: 48, fontSize: 18, textScale: 1)
    let metrics = TerminalFontMetrics.cellMetrics(for: render)
    let size = TerminalRenderGeometry.viewportGrid(configuration: render,
        logicalWidth: Double(width), logicalHeight: Double(height), cellWidth: metrics.width, lineHeight: metrics.height)
    var grid = TerminalGrid(columns: size.columns, rows: size.rows)
    let corners = [(0, 0), (size.columns - 1, 0), (0, size.rows - 1), (size.columns - 1, size.rows - 1)]
    grid.setStyle(.init(background: .rgb(255, 0, 255)))
    for (column, row) in corners {
        grid.moveCursor(column: column, row: row)
        grid.put(" ")
    }
    grid.setCursorVisible(false)
    let frame = try await terminalGPUFrame(grid.snapshot(), width: width, height: height, render: render)
    let layout = TerminalRenderGeometry.layout(columns: size.columns, rows: size.rows,
        cellWidth: metrics.width, lineHeight: metrics.height,
        targetWidth: Double(frame.1), targetHeight: Double(frame.2), mode: .fit)
    for (column, row) in corners {
        let x = Int(layout.offsetX + (Double(column) + 0.5) * metrics.width * layout.scale.x)
        let y = Int(layout.offsetY + (Double(row) + 0.5) * metrics.height * layout.scale.y)
        #expect((0..<frame.1).contains(x) && (0..<frame.2).contains(y))
        let index = (y * frame.1 + x) * 4
        #expect(frame.0[index] > 240 && frame.0[index + 2] > 240)
    }
}
