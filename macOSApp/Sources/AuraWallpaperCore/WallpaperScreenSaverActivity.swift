import Darwin

/// Read-only visibility check. It never starts a saver or establishes a lock.
public enum WallpaperScreenSaverActivity {
    private static let running: (@convention(c) () -> Bool)? = {
        guard let handle = dlopen(WallpaperPlatformConstants.loginFrameworkPath, RTLD_NOW | RTLD_LOCAL),
              let symbol = dlsym(handle, "SACScreenSaverIsRunning") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Bool).self)
    }()

    static func isVisible(locked: Bool?, saverRunning: Bool?) -> Bool {
        locked == true || saverRunning == true
    }
    public static func currentIsVisible() -> Bool {
        if LockScreenSession.currentIsLocked() == true { return true }
        return running?() == true
    }
}
