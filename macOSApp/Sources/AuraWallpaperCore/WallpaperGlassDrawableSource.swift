import QuartzCore
import Metal

/// The protected saver host can retain every drawable until its next CA
/// transaction. Never wait for that pool on the interactive/main thread.
final class WallpaperGlassDrawableSource: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.andrijvergeles.auraflow.glass-drawable", qos: .userInteractive,
        autoreleaseFrequency: .workItem)
    private let acquire: (CAMetalLayer) -> CAMetalDrawable?
    private var ready: CAMetalDrawable?
    private var pending = false
    private var generation: UInt64 = 0

    init(acquire: @escaping (CAMetalLayer) -> CAMetalDrawable? = { $0.nextDrawable() }) {
        self.acquire = acquire
    }

    func take(from layer: CAMetalLayer) -> CAMetalDrawable? {
        lock.lock()
        let result = ready
        ready = nil
        if !pending {
            pending = true
            let requestedGeneration = generation
            queue.async { [weak self, weak layer] in
                guard let self, let layer else { return }
                let drawable = self.acquire(layer)
                self.lock.lock()
                if self.generation == requestedGeneration { self.ready = drawable }
                self.pending = false
                self.lock.unlock()
            }
        }
        lock.unlock()
        return result
    }

    func stop() {
        lock.lock()
        generation &+= 1
        ready = nil
        // Keep a blocked request marked pending until its worker exits. A
        // hide/show cycle must not queue an unbounded number of pool waits.
        lock.unlock()
    }
}
