struct TerminalFullscreenPausePolicy {
    private(set) var isPaused = false
    var manuallyPaused = false
    var playbackIsPaused: Bool { manuallyPaused || isPaused }
    private var fullscreenSamples = 0

    mutating func update(
        enabled: Bool,
        screenLocked: Bool,
        foregroundIsFullscreen: Bool
    ) -> Bool? {
        guard enabled, !screenLocked else {
            fullscreenSamples = 0
            guard isPaused else { return nil }
            isPaused = false
            return false
        }

        if foregroundIsFullscreen {
            fullscreenSamples = min(fullscreenSamples + 1, 2)
            guard fullscreenSamples == 2, !isPaused else { return nil }
            isPaused = true
            return true
        }

        fullscreenSamples = 0
        // Debounce entering pause, but expose live playback as soon as the
        // covering window is gone. A second clear sample only freezes a
        // visible Desktop after closing, minimizing or leaving fullscreen.
        guard isPaused else { return nil }
        isPaused = false
        return false
    }

    mutating func restoreAfterFailedProcessSignal(to paused: Bool) {
        isPaused = paused
        fullscreenSamples = 0
    }
}
