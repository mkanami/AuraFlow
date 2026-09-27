struct TerminalFullscreenPausePolicy {
    private(set) var isPaused = false
    private var fullscreenSamples = 0
    private var windowedSamples = 0

    mutating func update(
        enabled: Bool,
        screenLocked: Bool,
        foregroundIsFullscreen: Bool
    ) -> Bool? {
        guard enabled, !screenLocked else {
            fullscreenSamples = 0
            windowedSamples = 0
            guard isPaused else { return nil }
            isPaused = false
            return false
        }

        if foregroundIsFullscreen {
            fullscreenSamples = min(fullscreenSamples + 1, 2)
            windowedSamples = 0
            guard fullscreenSamples == 2, !isPaused else { return nil }
            isPaused = true
            return true
        }

        windowedSamples = min(windowedSamples + 1, 2)
        fullscreenSamples = 0
        guard windowedSamples == 2, isPaused else { return nil }
        isPaused = false
        return false
    }

    mutating func restoreAfterFailedProcessSignal(to paused: Bool) {
        isPaused = paused
        fullscreenSamples = 0
        windowedSamples = 0
    }
}
