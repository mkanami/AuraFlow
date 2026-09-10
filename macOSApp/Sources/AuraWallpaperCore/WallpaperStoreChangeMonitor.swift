import Darwin
import Foundation

/// Watches the directory containing Apple's wallpaper store. WallpaperAgent
/// replaces Index.plist atomically, so watching the parent directory is more
/// reliable than keeping an open descriptor for the plist itself.
///
/// The monitor is intentionally generic and does not know about AuraFlow
/// ownership. Its callback is responsible for deciding whether a change is a
/// user Desktop route worth journaling.
internal final class WallpaperStoreChangeMonitor: @unchecked Sendable {
    private let directoryURL: URL
    private let queue: DispatchQueue
    private let callback: @Sendable () -> Void
    private let stateLock = NSLock()
    private var source: DispatchSourceFileSystemObject?
    private var scheduledCapture: DispatchWorkItem?
    private var stopped = true
    private var generation: UInt64 = 0

    internal init(
        directoryURL: URL,
        callback: @escaping @Sendable () -> Void
    ) {
        self.directoryURL = directoryURL
        self.queue = DispatchQueue(
            label: "com.andrijvergeles.auraflow.wallpaper-store-monitor",
            qos: .utility
        )
        self.callback = callback
    }

    internal func start() {
        stateLock.lock()
        guard source == nil else {
            stateLock.unlock()
            return
        }
        stopped = false
        stateLock.unlock()

        let descriptor = Darwin.open(
            directoryURL.path,
            O_EVTONLY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            stateLock.lock()
            stopped = true
            stateLock.unlock()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleCapture()
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }

        stateLock.lock()
        if stopped {
            stateLock.unlock()
            source.cancel()
            return
        }
        self.source = source
        stateLock.unlock()
        source.resume()
    }

    internal func stop() {
        let source: DispatchSourceFileSystemObject?
        stateLock.lock()
        stopped = true
        generation &+= 1
        scheduledCapture?.cancel()
        scheduledCapture = nil
        source = self.source
        self.source = nil
        stateLock.unlock()

        source?.cancel()
        // Wait for an already queued callback before the owner removes its
        // journal directory. The generation check prevents delayed work from
        // recreating that directory after Remove has completed.
        queue.sync {}
    }

    private func scheduleCapture() {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        generation &+= 1
        let captureGeneration = generation
        scheduledCapture?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let shouldCapture = !self.stopped
                && self.generation == captureGeneration
            if shouldCapture {
                self.scheduledCapture = nil
            }
            self.stateLock.unlock()
            guard shouldCapture else { return }
            self.callback()
        }
        scheduledCapture = workItem
        stateLock.unlock()

        // Atomic plist replacement can emit the directory event before the
        // replacement is readable. A short debounce also coalesces the burst
        // emitted by WallpaperAgent while it exports a new configuration.
        queue.asyncAfter(
            deadline: .now() + .milliseconds(80),
            execute: workItem
        )
    }
}
