import Foundation

public protocol LockScreenSaverInstalling {
    var isInstalled: Bool { get }

    func install(videoURL: URL) throws
    func installLockScreenOnly(videoURL: URL) throws
    func uninstall() throws
}

public extension LockScreenSaverInstalling {
    func installLockScreenOnly(videoURL: URL) throws {
        try install(videoURL: videoURL)
    }
}
