import AppKit
import AVFoundation
import Darwin
import Foundation
import ImageIO

public enum WallpaperRuntimeNotifications {
    public static let commandDidChange = Notification.Name(
        "com.andrijvergeles.auraflow.runtime-command-did-change"
    )
}

public enum WallpaperRuntimeCommandAction: String, Codable, Equatable {
    case reload
    case update
    case pause
    case resume
    case previewLock
    case previewUnlock
    case terminate
}

public struct WallpaperRuntimeCommand: Codable, Equatable {
    public var id: String
    public var action: WallpaperRuntimeCommandAction
    public var config: ControlConfig?
    public var created_at: Double

    public init(
        id: String = UUID().uuidString,
        action: WallpaperRuntimeCommandAction,
        config: ControlConfig? = nil,
        created_at: Double = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.action = action
        self.config = config
        self.created_at = created_at
    }
}

public final class WallpaperRuntimeStore {
    private struct LastFrameSourceRevision: Codable, Equatable {
        var path: String
        var size: UInt64?
        var modifiedAt: Double?
    }

    public let appSupportURL: URL
    private let launchAgentFileURL: URL

    public init(
        appSupportURL: URL = WallpaperRuntimeStore.defaultAppSupportURL(),
        launchAgentURL: URL? = nil
    ) {
        self.appSupportURL = appSupportURL
        self.launchAgentFileURL = launchAgentURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.andrijvergeles.auraflow.plist")
    }

    public static func defaultAppSupportURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AuraFlow", isDirectory: true)
    }

    public var configURL: URL { appSupportURL.appendingPathComponent("config.json") }
    public var commandURL: URL { appSupportURL.appendingPathComponent("daemon_command.json") }
    public var healthURL: URL { appSupportURL.appendingPathComponent("daemon_health.json") }
    public var pidURL: URL { appSupportURL.appendingPathComponent("wallpaper_daemon.pid") }
    public var pausedURL: URL { appSupportURL.appendingPathComponent("wallpaper_daemon.paused") }
    public var lastFrameURL: URL { appSupportURL.appendingPathComponent("last_frame.png") }
    public var lastFrameSourceURL: URL {
        appSupportURL.appendingPathComponent("last_frame_source.json")
    }
    public var launchAgentURL: URL { launchAgentFileURL }

    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    public func loadConfig() -> ControlConfig {
        guard let config: ControlConfig = try? readJSON(ControlConfig.self, from: configURL) else {
            return .defaultConfig
        }
        return normalized(config)
    }

    public func saveConfig(_ config: ControlConfig) throws {
        try writeJSON(normalized(config), to: configURL)
    }

    public func loadHealth() -> DaemonHealth? {
        try? readJSON(DaemonHealth.self, from: healthURL)
    }

    public func saveHealth(_ health: DaemonHealth) throws {
        try writeJSON(health, to: healthURL)
    }

    public func removeHealth() {
        try? FileManager.default.removeItem(at: healthURL)
    }

    public func loadCommand() -> WallpaperRuntimeCommand? {
        try? readJSON(WallpaperRuntimeCommand.self, from: commandURL)
    }

    public func saveCommand(_ command: WallpaperRuntimeCommand) throws {
        try writeJSON(command, to: commandURL)
    }

    public func removeCommand() {
        try? FileManager.default.removeItem(at: commandURL)
    }

    public func loadPID() -> Int? {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8) else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func savePID(_ pid: Int32 = getpid()) throws {
        try ensureDirectories()
        try "\(pid)\n".write(to: pidURL, atomically: true, encoding: .utf8)
    }

    public func removePID() {
        try? FileManager.default.removeItem(at: pidURL)
    }

    public func markPaused(_ paused: Bool) {
        if paused {
            try? ensureDirectories()
            FileManager.default.createFile(atPath: pausedURL.path, contents: Data(), attributes: nil)
        } else {
            try? FileManager.default.removeItem(at: pausedURL)
        }
    }

    public func isPaused() -> Bool {
        FileManager.default.fileExists(atPath: pausedURL.path)
    }

    public func processIsAlive(pid: Int?) -> Bool {
        guard let pid, pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0
    }

    public func normalized(_ config: ControlConfig) -> ControlConfig {
        var normalized = config
        normalized.lock_screen_path = normalized.lock_screen_path?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.lock_screen_path?.isEmpty == true {
            normalized.lock_screen_path = nil
        }
        normalized.lock_screen_runtime_path = normalized.lock_screen_runtime_path?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.lock_screen_runtime_path?.isEmpty == true {
            normalized.lock_screen_runtime_path = nil
        }
        normalized.playback_speed = max(0.1, min(config.playback_speed, 4.0))
        normalized.volume = max(0, min(config.volume ?? 0, 1))
        normalized.autostart = config.autostart ?? false
        normalized.blend_interpolation = config.blend_interpolation ?? false
        normalized.pause_on_fullscreen = config.pause_on_fullscreen ?? true
        let lockScreenPreferenceConfigured =
            config.lock_screen_preference_configured == true
        normalized.lock_screen_preference_configured = lockScreenPreferenceConfigured
        // Earlier versions enabled the Aerial-based Lock Screen integration
        // for every existing configuration. That integration rewrites the
        // system wallpaper store, so an implicit legacy default must never
        // modify a user's desktop. The toggle remains fully available once
        // the user explicitly enables it.
        normalized.show_on_lock_screen = lockScreenPreferenceConfigured
            ? (config.show_on_lock_screen ?? false)
            : false
        if WallpaperScaleMode(rawValue: config.scale_mode ?? "") == nil {
            normalized.scale_mode = WallpaperScaleMode.fill.rawValue
        }
        return normalized
    }

    public func status(wallpaperRestored: Bool? = nil, wallpaper: String? = nil) -> ControlStatus {
        let config = loadConfig()
        let pid = loadPID()
        let alive = processIsAlive(pid: pid)
        let paused = isPaused()
        let health = healthForStatus(alive: alive, paused: paused)
        return ControlStatus(
            running: alive && !paused,
            config: config,
            pid: alive ? pid : nil,
            autostart: launchAgentEnabled(),
            paused: paused,
            wallpaper_restored: wallpaperRestored,
            wallpaper: wallpaper,
            health: health
        )
    }

    public func metrics() -> DaemonMetrics {
        let pid = loadPID()
        let alive = processIsAlive(pid: pid)
        let paused = isPaused()
        let daemonPIDs = alive ? liveDaemonPIDs(rootPID: pid) : []
        let processMetrics = liveProcessMetrics(pid: alive ? pid : nil)
        return DaemonMetrics(
            updated_at: Date().timeIntervalSince1970,
            running: alive && !paused,
            paused: paused,
            pid: alive ? pid : nil,
            daemon_pids: daemonPIDs,
            process_count: daemonPIDs.count,
            cpu_percent: processMetrics.cpuPercent,
            memory_mb: processMetrics.memoryMB,
            virtual_memory_mb: processMetrics.virtualMemoryMB,
            thread_count: processMetrics.threadCount,
            health: healthForStatus(alive: alive, paused: paused)
        )
    }

    private func liveDaemonPIDs(rootPID: Int?) -> [Int] {
        guard let rootPID, rootPID > 0 else { return [] }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return [rootPID]
        }

        guard process.terminationStatus == 0,
              let text = String(
                  data: output.fileHandleForReading.readDataToEndOfFile(),
                  encoding: .utf8
              ) else {
            return [rootPID]
        }

        var parentByPID: [Int: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let values = line.split(whereSeparator: \.isWhitespace)
            guard values.count >= 2,
                  let pid = Int(values[0]),
                  let parentPID = Int(values[1]),
                  pid > 0 else {
                continue
            }
            parentByPID[pid] = parentPID
        }

        var daemonPIDs: Set<Int> = [rootPID]
        var didAddProcess = true
        while didAddProcess {
            didAddProcess = false
            for (pid, parentPID) in parentByPID where daemonPIDs.contains(parentPID) {
                if daemonPIDs.insert(pid).inserted {
                    didAddProcess = true
                }
            }
        }
        return daemonPIDs.sorted()
    }

    private struct LiveProcessMetrics {
        var cpuPercent: Double?
        var memoryMB: Double?
        var virtualMemoryMB: Double?
        var threadCount: Int?
    }

    /// Reads metrics for the daemon itself instead of reporting placeholders.
    ///
    /// `proc_pidinfo` is the native macOS process API and gives us memory and
    /// thread data without scraping a UI or assuming a particular display. CPU
    /// percentage is read from the system `ps` snapshot because it already
    /// applies macOS's process CPU accounting and does not require mutable
    /// sampling state in this store.
    private func liveProcessMetrics(pid: Int?) -> LiveProcessMetrics {
        guard let pid, pid > 0 else {
            return LiveProcessMetrics(
                cpuPercent: nil,
                memoryMB: nil,
                virtualMemoryMB: nil,
                threadCount: nil
            )
        }

        var taskInfo = proc_taskinfo()
        let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let taskInfoResult = proc_pidinfo(
            pid_t(pid),
            PROC_PIDTASKINFO,
            0,
            &taskInfo,
            taskInfoSize
        )

        let memoryMB: Double?
        let virtualMemoryMB: Double?
        let threadCount: Int?
        if taskInfoResult == taskInfoSize {
            memoryMB = Double(taskInfo.pti_resident_size) / 1_048_576.0
            virtualMemoryMB = Double(taskInfo.pti_virtual_size) / 1_048_576.0
            threadCount = taskInfo.pti_threadnum > 0 ? Int(taskInfo.pti_threadnum) : nil
        } else {
            memoryMB = nil
            virtualMemoryMB = nil
            threadCount = nil
        }

        return LiveProcessMetrics(
            cpuPercent: processCPUPercent(pid: pid),
            memoryMB: memoryMB,
            virtualMemoryMB: virtualMemoryMB,
            threadCount: threadCount
        )
    }

    private func processCPUPercent(pid: Int) -> Double? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "pcpu="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0,
              let text = String(
                  data: output.fileHandleForReading.readDataToEndOfFile(),
                  encoding: .utf8
              ),
              let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite else {
            return nil
        }
        return max(value, 0)
    }

    public func healthForStatus(alive: Bool, paused: Bool) -> DaemonHealth {
        let now = Date().timeIntervalSince1970
        let config = loadConfig()
        let saved = loadHealth()
        let lag = saved?.updated_at.map { max(now - $0, 0) }
        let fresh = alive && (lag ?? 0) < 6.0
        return DaemonHealth(
            available: alive,
            fresh: fresh,
            suspicious: alive && !fresh,
            reason: alive ? (fresh ? "ok" : "stale-health") : "not-running",
            updated_at: saved?.updated_at ?? now,
            lag_seconds: lag,
            screens: saved?.screens,
            windows: saved?.windows,
            player_rate: paused ? 0 : saved?.player_rate,
            stall_events: saved?.stall_events ?? 0,
            recovery_events: saved?.recovery_events ?? 0,
            consecutive_stall_polls: saved?.consecutive_stall_polls ?? 0,
            paused: paused,
            manual_paused: paused,
            low_power_mode: saved?.low_power_mode ?? false,
            auto_paused_for_low_power: saved?.auto_paused_for_low_power ?? false,
            pause_on_fullscreen: saved?.pause_on_fullscreen,
            fullscreen_app_detected: saved?.fullscreen_app_detected ?? false,
            auto_paused_for_fullscreen: saved?.auto_paused_for_fullscreen ?? false,
            lock_screen_enabled: saved?.lock_screen_enabled ?? config.show_on_lock_screen ?? false,
            session_inactive: saved?.session_inactive ?? false,
            lock_screen_preview_active: saved?.lock_screen_preview_active ?? false,
            presentation_mode: saved?.presentation_mode ?? WallpaperPresentationMode.desktop.rawValue,
            lock_transition_count: saved?.lock_transition_count ?? 0,
            last_lock_transition_ms: saved?.last_lock_transition_ms,
            blend_interpolation_enabled: saved?.blend_interpolation_enabled ?? false,
            blend_interpolation_active: saved?.blend_interpolation_active ?? false,
            scale_mode: saved?.scale_mode ?? loadConfig().scale_mode
        )
    }

    public func launchAgentEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    public func enableLaunchAgent(helperPath: String) throws {
        try ensureDirectories()
        let configPath = configURL.path
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>com.andrijvergeles.auraflow</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(helperPath.escapedXML)</string>
            <string>--config</string>
            <string>\(configPath.escapedXML)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <false/>
        </dict>
        </plist>
        """
        try plist.write(to: launchAgentURL, atomically: true, encoding: .utf8)
        _ = runLaunchctl(["bootstrap", "gui/\(getuid())", launchAgentURL.path])
    }

    public func disableLaunchAgent() {
        _ = runLaunchctl(["bootout", "gui/\(getuid())/com.andrijvergeles.auraflow"])
        try? FileManager.default.removeItem(at: launchAgentURL)
    }

    @discardableResult
    public func terminateDaemon(timeout: TimeInterval = 1.0) -> Bool {
        guard let pid = loadPID(), processIsAlive(pid: pid) else {
            removePID()
            markPaused(false)
            return true
        }
        kill(pid_t(pid), SIGTERM)
        let deadline = Date().addingTimeInterval(max(timeout, 0.2))
        while Date() < deadline {
            if !processIsAlive(pid: pid) {
                removePID()
                markPaused(false)
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        kill(pid_t(pid), SIGKILL)
        let killDeadline = Date().addingTimeInterval(1.0)
        while Date() < killDeadline {
            if !processIsAlive(pid: pid) {
                removePID()
                markPaused(false)
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    public func captureStillFrame(from videoURL: URL, time: CMTime = CMTime(seconds: 0.2, preferredTimescale: 600)) throws -> URL {
        try ensureDirectories()
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 3840, height: 2160)
        let image = try generator.copyCGImage(at: time, actualTime: nil)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw WallpaperRuntimeError.unavailable("Could not encode wallpaper frame.")
        }
        try data.write(to: lastFrameURL, options: .atomic)
        try writeJSON(
            sourceRevision(for: videoURL),
            to: lastFrameSourceURL
        )
        return lastFrameURL
    }

    /// Converts a static image into a tiny H.264 movie for Apple's Lock Screen
    /// providers. The desktop agent renders images natively and never needs
    /// this conversion. The cached movie is keyed by the image's file
    /// revision, so selecting a different image cannot reuse stale pixels.
    public func ensureLockScreenVideo(from sourceURL: URL) throws -> URL {
        guard WallpaperMediaKind.forURL(sourceURL).isStaticImage else {
            return sourceURL.standardizedFileURL
        }
        try ensureDirectories()

        let sourceRevisionURL = appSupportURL
            .appendingPathComponent("lock_screen_video_source.json")
        let outputURL = appSupportURL
            .appendingPathComponent("lock_screen_video.mov")
        let revision = imageSourceRevision(for: sourceURL)
        if FileManager.default.fileExists(atPath: outputURL.path),
           (try? readJSON(ImageSourceRevision.self, from: sourceRevisionURL)) == revision {
            return outputURL
        }

        guard let imageSource = CGImageSourceCreateWithURL(
            sourceURL as CFURL,
            nil
        ),
        let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw WallpaperRuntimeError.unavailable(
                "Could not read the selected Lock Screen image."
            )
        }

        let width = max(2, cgImage.width - (cgImage.width % 2))
        let height = max(2, cgImage.height - (cgImage.height % 2))
        let temporaryURL = appSupportURL
            .appendingPathComponent(".lock_screen_video.\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else {
            throw WallpaperRuntimeError.unavailable(
                "Could not prepare the Lock Screen image encoder."
            )
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? WallpaperRuntimeError.unavailable(
                "Could not start the Lock Screen image encoder."
            )
        }
        writer.startSession(atSourceTime: .zero)

        guard let pixelBuffer = makePixelBuffer(
            from: cgImage,
            width: width,
            height: height
        ) else {
            writer.cancelWriting()
            throw WallpaperRuntimeError.unavailable(
                "Could not prepare the Lock Screen image frame."
            )
        }
        guard input.isReadyForMoreMediaData,
              adaptor.append(pixelBuffer, withPresentationTime: .zero),
              adaptor.append(pixelBuffer, withPresentationTime: CMTime(seconds: 1, preferredTimescale: 600))
        else {
            writer.cancelWriting()
            throw writer.error ?? WallpaperRuntimeError.unavailable(
                "Could not encode the Lock Screen image frame."
            )
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else {
            throw writer.error ?? WallpaperRuntimeError.unavailable(
                "Could not finish the Lock Screen image movie."
            )
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
        }
        try writeJSON(revision, to: sourceRevisionURL)
        return outputURL
    }

    public func removeManagedLockScreenVideo() {
        try? FileManager.default.removeItem(
            at: appSupportURL.appendingPathComponent("lock_screen_video.mov")
        )
        try? FileManager.default.removeItem(
            at: appSupportURL.appendingPathComponent("lock_screen_video_source.json")
        )
    }

    public func ensureCurrentStillFrame(from videoURL: URL) throws -> URL {
        let expectedRevision = sourceRevision(for: videoURL)
        let savedRevision: LastFrameSourceRevision? =
            try? readJSON(
                LastFrameSourceRevision.self,
                from: lastFrameSourceURL
            )
        if FileManager.default.fileExists(atPath: lastFrameURL.path),
           savedRevision == expectedRevision {
            return lastFrameURL
        }
        return try captureStillFrame(from: videoURL)
    }

    public func removeManagedFallback() {
        try? FileManager.default.removeItem(at: lastFrameURL)
        try? FileManager.default.removeItem(at: lastFrameSourceURL)
    }

    @discardableResult
    public func applyStillWallpaper(from videoPath: String) -> String? {
        guard !videoPath.isEmpty else { return nil }
        let videoURL = URL(fileURLWithPath: videoPath)
        guard FileManager.default.fileExists(atPath: videoURL.path) else { return nil }
        guard let frameURL = try? captureStillFrame(from: videoURL) else { return nil }
        WallpaperDesktopSupport.applyToAllDesktops(imagePath: frameURL.path)
        return frameURL.path
    }

    @discardableResult
    public func restoreWallpaperBackup() -> Bool {
        WallpaperDesktopSupport.restoreFromBackupFiles(appSupportPath: appSupportURL.path)
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }

    private func sourceRevision(for videoURL: URL) -> LastFrameSourceRevision {
        let standardizedURL = videoURL.standardizedFileURL
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: standardizedURL.path
        )
        return LastFrameSourceRevision(
            path: standardizedURL.path,
            size: (attributes?[.size] as? NSNumber)?.uint64Value,
            modifiedAt: (attributes?[.modificationDate] as? Date)?
                .timeIntervalSince1970
        )
    }

    private struct ImageSourceRevision: Codable, Equatable {
        var path: String
        var size: UInt64?
        var modifiedAt: Double?
    }

    private func imageSourceRevision(for imageURL: URL) -> ImageSourceRevision {
        let standardizedURL = imageURL.standardizedFileURL
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: standardizedURL.path
        )
        return ImageSourceRevision(
            path: standardizedURL.path,
            size: (attributes?[.size] as? NSNumber)?.uint64Value,
            modifiedAt: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970
        )
    }

    private func makePixelBuffer(
        from image: CGImage,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            attributes as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess,
        let pixelBuffer
        else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: baseAddress,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
              )
        else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    private func runLaunchctl(_ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}

public enum WallpaperRuntimeError: LocalizedError {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        }
    }
}

private extension String {
    var escapedXML: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
