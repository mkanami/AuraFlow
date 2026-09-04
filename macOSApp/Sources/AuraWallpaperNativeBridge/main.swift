import AppKit
import AuraWallpaperCore
import Darwin
import Foundation

@MainActor
private final class NativeLockScreenBridgeServer: NSObject, NSApplicationDelegate {
    private let bridge = NativeLockScreenWallpaperBridge()
    private let transport = NativeBridgeTransport()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { [weak self] in
            guard let self else { return }
            await self.transport.start(
                onRequest: { [weak self] request in
                    // Transport decoding happens off the Main Actor. Keep the
                    // actor hop explicit before touching the bridge or AppKit.
                    let server = self
                    Task {
                        await MainActor.run {
                            server?.handle(request)
                        }
                    }
                },
                onClosed: {
                    Task {
                        await MainActor.run {
                            NSApp.terminate(nil)
                        }
                    }
                }
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge.shutdown()
        Task {
            await transport.stop()
        }
    }

    private func handle(_ request: NativeLockScreenBridgeRequest) {
        switch request.action {
        case .capabilities:
            let capabilities = NativeLockScreenWallpaperBridge
                .runtimeCapabilities()
            respond(
                to: request,
                succeeded: capabilities.isCompatible,
                errorDescription: capabilities.isCompatible
                    ? nil
                    : "Native bridge capability handshake failed.",
                capabilities: capabilities
            )
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
            respond(to: request, succeeded: true, terminateAfterWrite: true)
        }
    }

    private func respond(
        to request: NativeLockScreenBridgeRequest,
        succeeded: Bool,
        errorDescription: String? = nil,
        capabilities: NativeLockScreenBridgeRuntimeCapabilities? = nil,
        terminateAfterWrite: Bool = false
    ) {
        let response = NativeLockScreenBridgeResponse(
            id: request.id,
            action: request.action,
            succeeded: succeeded,
            errorDescription: errorDescription,
            capabilities: capabilities
        )
        Task { [weak self] in
            guard let self else { return }
            await transport.send(response)
            guard terminateAfterWrite else { return }
            await MainActor.run {
                NSApp.terminate(nil)
            }
        }
    }
}

let bridgeExecutableURL = Bundle.main.executableURL
    ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let bridgeCapabilities = NativeLockScreenBridgeCapabilityChecker.check(
    executableURL: bridgeExecutableURL
)
guard bridgeCapabilities.isAvailable else {
    fputs(
        "AuraWallpaperNativeBridge unavailable: "
            + bridgeCapabilities.message
            + "\n",
        stderr
    )
    // EX_CONFIG: the process cannot provide this optional platform route.
    exit(78)
}

let application = NSApplication.shared
MainActor.assumeIsolated {
    let delegate = NativeLockScreenBridgeServer()
    application.delegate = delegate
    application.run()
}
