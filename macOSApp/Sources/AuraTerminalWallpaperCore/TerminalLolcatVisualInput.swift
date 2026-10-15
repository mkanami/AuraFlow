import Darwin
import Foundation

/// A persistent, bounded text stream for lolcat's default wallpaper launch.
/// lolcat itself colors every frame; no process restart, shell pipeline,
/// audio or user-file input is needed. Explicit arguments remain authoritative.
// Mutable feed state is confined to queue, including synchronous cleanup.
final class TerminalLolcatVisualInput: @unchecked Sendable {
    static func applies(to command: TerminalCommandConfiguration, executable: String) -> Bool {
        command.arguments.isEmpty && URL(fileURLWithPath: executable).lastPathComponent == "lolcat"
    }

    let directory: URL
    let fifoURL: URL
    var arguments: [String] { ["--force", "--truecolor", fifoURL.path] }
    private let queue = DispatchQueue(label: "com.andrijvergeles.auraflow.lolcat-visual", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var descriptor: Int32 = -1
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var paused = false
    private var columns: Int
    private var rows: Int
    private var phase: Double = 0
    private var pending = Data()
    private var offset = 0

    init(columns: Int, rows: Int, temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws {
        directory = temporaryDirectory.appendingPathComponent("AuraFlow-lolcat-\(UUID().uuidString)", isDirectory: true)
        fifoURL = directory.appendingPathComponent("rainbow-frames.fifo")
        self.columns = min(max(columns, 1), 1000)
        self.rows = min(max(rows, 1), 500)
        queue.setSpecific(key: queueKey, value: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            guard mkfifo(fifoURL.path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            // Owned read end prevents SIGPIPE after the child exits. Writes
            // never block; CLOEXEC prevents inheritance by child processes.
            descriptor = open(fifoURL.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            if descriptor >= 0 { close(descriptor); descriptor = -1 }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func sample(columns: Int, rows: Int, phase: Double = 0) -> String {
        // Match the normalized PTY dimensions, including its last row/column.
        // No trailing newline: it would scroll a full grid and leave a blank
        // bottom row. The bound matches TerminalRenderConfiguration's limit.
        let width = min(max(columns, 1), 1000)
        let height = min(max(rows, 1), 500)
        let glyphs = Array(" .:-=+*#%@")
        let lines = (0..<height).map { row in
            String((0..<width).map { column in
                let x = Double(column) / Double(width) * 6 - 3
                let y = Double(row) / Double(height) * 4 - 2
                let wave = (sin(hypot(x, y) * 8 + sin(x * 2 + phase * 0.3) - phase) + 1) * 0.5
                return glyphs[min(Int(wave * Double(glyphs.count)), glyphs.count - 1)]
            })
        }
        return "\u{1b}[?25l\u{1b}[H" + lines.joined(separator: "\r\n")
    }

    func start() {
        queue.sync {
            guard !stopped, timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: 1.0 / 12, leeway: .milliseconds(3))
            source.setEventHandler { [weak self] in self?.writeNextFrame() }
            timer = source
            source.resume()
        }
    }

    private func writeNextFrame() {
        guard !stopped, !paused else { return }
        // Keep only one incomplete frame. A slow consumer applies backpressure
        // rather than building an unbounded queue or dropping partial ANSI.
        if offset == pending.count {
            pending = Data(Self.sample(columns: columns, rows: rows, phase: phase).utf8)
            phase += 0.16
            offset = 0
        }
        pending.withUnsafeBytes { bytes in
            let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count > 0 { offset += count }
        }
    }

    func resize(columns: Int, rows: Int) {
        queue.async { [weak self] in
            self?.columns = min(max(columns, 1), 1000)
            self?.rows = min(max(rows, 1), 500)
        }
    }

    func setPaused(_ value: Bool) { queue.async { [weak self] in self?.paused = value } }

    func stop() {
        let cleanup = {
            guard !self.stopped else { return }
            self.stopped = true
            self.timer?.setEventHandler {}
            self.timer?.cancel()
            self.timer = nil
            self.pending = Data()
            if self.descriptor >= 0 { close(self.descriptor); self.descriptor = -1 }
            try? FileManager.default.removeItem(at: self.directory)
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { cleanup() }
        else { queue.sync(execute: cleanup) }
    }
    deinit { stop() }
}
