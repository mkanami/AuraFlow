import Darwin
import Foundation

/// CAVA's FIFO backend accepts generated numbers without opening an audio
/// device. This is a visual animation, not microphone/system-audio capture,
/// and these samples are never played or saved as an audio recording.
// Mutable feed state is confined to queue, including synchronous cleanup.
final class TerminalCavaVisualInput: @unchecked Sendable {
    static func applies(to command: TerminalCommandConfiguration, executable: String) -> Bool {
        command.arguments.isEmpty && URL(fileURLWithPath: executable).lastPathComponent == "cava"
    }

    let directory: URL
    let configurationURL: URL
    let fifoURL: URL
    private let queue = DispatchQueue(label: "com.andrijvergeles.auraflow.cava-visual", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var descriptor: Int32 = -1
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var paused = false
    private var signal = TerminalCavaVisualSignal()

    init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) throws {
        directory = temporaryDirectory.appendingPathComponent("AuraFlow-cava-\(UUID().uuidString)", isDirectory: true)
        configurationURL = directory.appendingPathComponent("config")
        fifoURL = directory.appendingPathComponent("visual-input.fifo")
        queue.setSpecific(key: queueKey, value: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            guard mkfifo(fifoURL.path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            // Our read end prevents SIGPIPE when CAVA exits first. CLOEXEC
            // ensures no child inherits this owned descriptor.
            descriptor = open(fifoURL.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try Data(Self.configuration(fifoPath: fifoURL.path).utf8).write(to: configurationURL, options: .atomic)
        } catch {
            if descriptor >= 0 { close(descriptor); descriptor = -1 }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func configuration(fifoPath: String) -> String {
        """
        [general]
        framerate = 30
        bars = 0
        bar_width = 2
        bar_spacing = 1
        autosens = 1
        lower_cutoff_freq = 50
        higher_cutoff_freq = 10000
        sleep_timer = 0
        [input]
        method = fifo
        source = \(fifoPath)
        sample_rate = 44100
        sample_bits = 16
        [output]
        method = noncurses
        channels = mono
        mono_option = average
        disable_blanking = 0
        [color]
        gradient = 1
        gradient_color_1 = '#43d9d1'
        gradient_color_2 = '#6385ff'
        gradient_color_3 = '#cd6df4'
        [smoothing]
        noise_reduction = 70

        """
    }

    func start() {
        queue.sync {
            guard !stopped, timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: 512.0 / 44_100.0, leeway: .milliseconds(1))
            source.setEventHandler { [weak self] in
                guard let self, !self.stopped, !self.paused else { return }
                let bytes = self.signal.nextChunk()
                // 2048 bytes < PIPE_BUF. A full/paused FIFO returns EAGAIN;
                // never block the UI, allocate a backlog or spin on write.
                bytes.withUnsafeBytes { buffer in
                    _ = Darwin.write(self.descriptor, buffer.baseAddress, buffer.count)
                }
            }
            timer = source
            source.resume()
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
            if self.descriptor >= 0 { close(self.descriptor); self.descriptor = -1 }
            // This UUID directory and its two files belong only to this feed.
            try? FileManager.default.removeItem(at: self.directory)
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { cleanup() }
        else { queue.sync(execute: cleanup) }
    }

    deinit { stop() }
}

/// Deterministic, slowly modulated spectrum. Oscillator recurrence keeps sine
/// calls out of the sample loop; the small fixed buffer is bounded per tick.
struct TerminalCavaVisualSignal {
    private var frame: UInt64 = 0
    private var real: [Double] = Array(repeating: 1, count: 32)
    private var imaginary: [Double] = Array(repeating: 0, count: 32)
    private let cosine: [Double]
    private let sine: [Double]

    init() {
        let steps = (0..<32).map { 2 * Double.pi * (70 * pow(100, Double($0) / 31)) / 44_100 }
        cosine = steps.map(cos)
        sine = steps.map(sin)
    }

    mutating func nextChunk() -> Data {
        let time = Double(frame) / 44_100
        let amplitudes = (0..<32).map { index in
            0.1 + 0.9 * pow(0.5 + 0.5 * sin(time * (0.65 + Double(index % 7) * 0.14) + Double(index) * 0.57), 2)
        }
        var samples = [Int16](repeating: 0, count: 1024)
        // This also runs in debug app builds: avoid generic Range iterators
        // in the high-frequency inner loop.
        var sample = 0
        while sample < 512 {
            var value = 0.0
            var band = 0
            while band < 32 {
                value += imaginary[band] * amplitudes[band]
                let nextReal = real[band] * cosine[band] - imaginary[band] * sine[band]
                imaginary[band] = imaginary[band] * cosine[band] + real[band] * sine[band]
                real[band] = nextReal
                band += 1
            }
            let scaled = Int16(max(-32_000, min(32_000, value * 850))).littleEndian
            samples[sample * 2] = scaled
            samples[sample * 2 + 1] = scaled
            sample += 1
        }
        frame &+= 512
        return samples.withUnsafeBytes { Data($0) }
    }
}
