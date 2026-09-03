import AppKit
import AuraWallpaperCore
import Foundation

private final class NativeLockScreenBridgeServer: NSObject, NSApplicationDelegate {
    private let bridge = NativeLockScreenWallpaperBridge()
    private let inputQueue = DispatchQueue(
        label: "com.auraflow.native-lock-screen-bridge-input"
    )
    private let outputLock = NSLock()
    private var inputBuffer = Data()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            do {
                guard let data = try handle.read(upToCount: 64 * 1024),
                      !data.isEmpty
                else {
                    DispatchQueue.main.async {
                        NSApp.terminate(nil)
                    }
                    return
                }
                self?.inputQueue.async { [weak self] in
                    self?.consume(data)
                }
            } catch {
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        FileHandle.standardInput.readabilityHandler = nil
        bridge.shutdown()
    }

    private func consume(_ data: Data) {
        inputBuffer.append(data)
        while let newline = inputBuffer.firstIndex(of: 0x0A) {
            let line = inputBuffer.prefix(upTo: newline)
            inputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let request = try? JSONDecoder().decode(
                      NativeLockScreenBridgeRequest.self,
                      from: line
                  )
            else {
                continue
            }
            DispatchQueue.main.async { [weak self] in
                self?.handle(request)
            }
        }
    }

    private func handle(_ request: NativeLockScreenBridgeRequest) {
        switch request.action {
        case .prepare:
            bridge.prepare { [weak self] succeeded, errorDescription in
                self?.respond(
                    to: request,
                    succeeded: succeeded,
                    errorDescription: errorDescription
                )
            }
        case .show:
            bridge.showForLockTransition { [weak self] succeeded, errorDescription in
                self?.respond(
                    to: request,
                    succeeded: succeeded,
                    errorDescription: errorDescription
                )
            }
        case .hide:
            bridge.hideAfterUnlock()
            respond(to: request, succeeded: true)
        case .pause:
            bridge.pause()
            respond(to: request, succeeded: true)
        case .resume:
            bridge.resumeAfterPause()
            respond(to: request, succeeded: true)
        case .shutdown:
            bridge.shutdown()
            respond(to: request, succeeded: true)
            NSApp.terminate(nil)
        }
    }

    private func respond(
        to request: NativeLockScreenBridgeRequest,
        succeeded: Bool,
        errorDescription: String? = nil
    ) {
        let response = NativeLockScreenBridgeResponse(
            id: request.id,
            action: request.action,
            succeeded: succeeded,
            errorDescription: errorDescription
        )
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        outputLock.lock()
        defer { outputLock.unlock() }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}

guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else {
    exit(1)
}

let application = NSApplication.shared
private let delegate = NativeLockScreenBridgeServer()
application.delegate = delegate
application.run()
