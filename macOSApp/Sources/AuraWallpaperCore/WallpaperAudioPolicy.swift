import Foundation

public enum WallpaperAudioPolicy {
    public static func normalized(_ volume: Double) -> Double {
        volume.isFinite ? min(1, max(0, volume)) : 0
    }

    /// The shared Desktop player owns audio across all displays. Secure/idle
    /// presentation and sleeping must never turn its prewarmed video into sound.
    public static func desktopVolume(_ volume: Double, lockScreenOnly: Bool,
        sessionInactive: Bool, systemLocked: Bool, sleeping: Bool,
        screenSaverActive: Bool = false, paused: Bool = false, desktopObstructed: Bool = false) -> Float {
        guard !lockScreenOnly, !sessionInactive, !systemLocked, !sleeping,
              !screenSaverActive, !paused, !desktopObstructed else { return 0 }
        return Float(normalized(volume))
    }

    public static func previewVolume(_ volume: Double, desktopOwnsAudio: Bool, visible: Bool, systemLocked: Bool = false) -> Float {
        // A preview itself is an application window. It never owns music.
        return 0
    }
}
