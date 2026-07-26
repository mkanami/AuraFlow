import Foundation

public protocol LockScreenSaverInstalling {
    var isInstalled: Bool { get }

    func install(videoURL: URL) throws
    func uninstall() throws
}
