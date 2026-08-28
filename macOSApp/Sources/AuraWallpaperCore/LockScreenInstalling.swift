import Foundation

public protocol LockScreenSaverInstalling {
    var isInstalled: Bool { get }
    var installationConfirmed: Bool { get }

    func install(videoURL: URL) throws
    func installLockScreenOnly(videoURL: URL) throws
    func uninstall() throws
    func uninstallLockScreenOnlyPreservingCurrentDesktop() throws
}

public extension LockScreenSaverInstalling {
    var installationConfirmed: Bool {
        isInstalled
    }

    func installLockScreenOnly(videoURL: URL) throws {
        try install(videoURL: videoURL)
    }

    func uninstallLockScreenOnlyPreservingCurrentDesktop() throws {
        try uninstall()
    }
}
