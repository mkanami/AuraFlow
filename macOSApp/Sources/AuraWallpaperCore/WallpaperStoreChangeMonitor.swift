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
    private let storeURL: URL
    private let queue: DispatchQueue
    private let callback: @Sendable (Data) -> Void
    private let stateLock = NSLock()
    private var source: DispatchSourceFileSystemObject?
    private var pollingTimer: DispatchSourceTimer?
    private var scheduledCapture: DispatchWorkItem?
    private var lastObservedStoreData: Data?
    private var stopped = true
    private var generation: UInt64 = 0

    internal init(
        directoryURL: URL,
        storeURL: URL,
        callback: @escaping @Sendable (Data) -> Void
    ) {
        self.directoryURL = directoryURL
        self.storeURL = storeURL
        self.queue = DispatchQueue(
            label: "com.andrijvergeles.auraflow.wallpaper-store-monitor",
            qos: .utility
        )
        self.callback = callback
    }

    @discardableResult
    internal func start() -> Bool {
        stateLock.lock()
        guard source == nil else {
            stateLock.unlock()
            return true
        }
        stopped = false
        lastObservedStoreData = try? Data(contentsOf: storeURL)
        stateLock.unlock()

        let descriptor = Darwin.open(
            directoryURL.path,
            O_EVTONLY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            stateLock.lock()
            stopped = true
            stateLock.unlock()
            return false
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
            return false
        }
        self.source = source

        // WallpaperAgent can replace Index.plist twice within one filesystem
        // event burst. In particular, ordinary image wallpapers can exist in
        // the store for less than a second before the agent reasserts Aerial.
        // Polling the small plist closes that race when the directory event is
        // coalesced or delivered after the second replacement.
        let pollingTimer = DispatchSource.makeTimerSource(queue: queue)
        pollingTimer.schedule(
            deadline: .now() + .milliseconds(50),
            repeating: .milliseconds(50),
            leeway: .milliseconds(15)
        )
        pollingTimer.setEventHandler { [weak self] in
            self?.observeStoreForChanges()
        }
        self.pollingTimer = pollingTimer
        stateLock.unlock()
        source.resume()
        pollingTimer.resume()
        return true
    }

    internal func stop() {
        let source: DispatchSourceFileSystemObject?
        let pollingTimer: DispatchSourceTimer?
        stateLock.lock()
        stopped = true
        generation &+= 1
        scheduledCapture?.cancel()
        scheduledCapture = nil
        source = self.source
        self.source = nil
        pollingTimer = self.pollingTimer
        self.pollingTimer = nil
        lastObservedStoreData = nil
        stateLock.unlock()

        source?.cancel()
        pollingTimer?.cancel()
        // Wait for an already queued callback before the owner removes its
        // journal directory. The generation check prevents delayed work from
        // recreating that directory after Remove has completed.
        queue.sync {}
    }

    private func observeStoreForChanges() {
        guard let currentData = try? Data(contentsOf: storeURL) else {
            return
        }

        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        let changed = lastObservedStoreData != currentData
        if changed {
            lastObservedStoreData = currentData
        }
        stateLock.unlock()

        guard changed else { return }

        // Do not defer this snapshot until the directory debounce fires.
        // WallpaperAgent can replace the user's image with Aura's Aerial
        // route before that deferred read happens.
        callback(currentData)
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
            guard let storeData = try? Data(contentsOf: self.storeURL) else {
                return
            }
            self.callback(storeData)
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
