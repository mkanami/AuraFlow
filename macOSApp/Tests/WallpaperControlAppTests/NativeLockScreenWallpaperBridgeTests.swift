import Foundation
import Testing
@testable import AuraWallpaperAgent

private enum NativeBridgeFixtureMode {
    case responds
    case exitsDuringRequest
    case doesNotRespond
    case sendsMalformedJSON
    case rejectsPrepare
    case crashesOnce
    case sendsUnknownResponseBeforeValidResponse
}

private final class NativeBridgeFixture {
    let root: URL
    let executableURL: URL

    init(_ mode: NativeBridgeFixtureMode) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AuraFlowNativeBridgeTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        executableURL = root.appendingPathComponent("bridge.sh")
        let markerURL = root.appendingPathComponent("first-process.marker")
        let script = Self.script(for: mode, markerURL: markerURL)
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func script(
        for mode: NativeBridgeFixtureMode,
        markerURL: URL
    ) -> String {
        let marker = shellQuote(markerURL.path)
        switch mode {
        case .responds:
            return responseLoop(exitOnShutdown: true)
        case .exitsDuringRequest:
            return "#!/bin/sh\nexit 0\n"
        case .doesNotRespond:
            return "#!/bin/sh\nwhile IFS= read -r line; do :; done\n"
        case .sendsMalformedJSON:
            return "#!/bin/sh\nwhile IFS= read -r line; do printf '%s\\n' '{not-json}'; done\n"
        case .rejectsPrepare:
            return responseLoop(
                prepareSucceeded: false,
                prepareError: "fixture prepare failed",
                exitOnShutdown: true
            )
        case .crashesOnce:
            return """
            #!/bin/sh
            if [ ! -e \(marker) ]; then
              : > \(marker)
              exit 0
            fi
            \(responseLoop(exitOnShutdown: true).dropFirst("#!/bin/sh\n".count))
            """
        case .sendsUnknownResponseBeforeValidResponse:
            return """
            #!/bin/sh
            while IFS= read -r line; do
              id=$(printf '%s' "$line" | sed -n 's/.*"id":"\\([^"]*\\)".*/\\1/p')
              action=$(printf '%s' "$line" | sed -n 's/.*"action":"\\([^"]*\\)".*/\\1/p')
              printf '{"id":"stale-response","action":"%s","succeeded":true}\\n' "$action"
              printf '{"id":"%s","action":"%s","succeeded":true}\\n' "$id" "$action"
              if [ "$action" = "shutdown" ]; then exit 0; fi
            done
            """
        }
    }

    private static func responseLoop(
        prepareSucceeded: Bool = true,
        prepareError: String? = nil,
        exitOnShutdown: Bool
    ) -> String {
        let escapedError = prepareError.map(shellQuote) ?? "''"
        var prepareResponse = ""
        if prepareSucceeded {
            prepareResponse = "printf '{\"id\":\"%s\",\"action\":\"%s\",\"succeeded\":true}\\n' \"$id\" \"$action\""
        } else {
            prepareResponse = "printf '{\"id\":\"%s\",\"action\":\"%s\",\"succeeded\":false,\"errorDescription\":\"%s\"}\\n' \"$id\" \"$action\" \(escapedError)"
        }
        let shutdown = exitOnShutdown
            ? "if [ \"$action\" = \"shutdown\" ]; then exit 0; fi\n"
            : ""
        return """
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":"\\([^"]*\\)".*/\\1/p')
          action=$(printf '%s' "$line" | sed -n 's/.*"action":"\\([^"]*\\)".*/\\1/p')
          if [ "$action" = "prepare" ]; then
            \(prepareResponse)
          else
            printf '{"id":"%s","action":"%s","succeeded":true}\\n' "$id" "$action"
          fi
          \(shutdown)
        done
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private func awaitBridgeResult(
    _ operation: @escaping @Sendable (
        @escaping @Sendable (Bool) -> Void
    ) -> Void
) async -> Bool {
    await withCheckedContinuation { continuation in
        operation { succeeded in
            continuation.resume(returning: succeeded)
        }
    }
}

private func stopBridge(
    _ bridge: NativeLockScreenWallpaperBridge,
    fixture: NativeBridgeFixture
) {
    bridge.shutdown()
    Thread.sleep(forTimeInterval: 0.35)
    fixture.cleanup()
}

@Test func nativeBridgeCompletesPrepareAndShowOverJSONLines() async throws {
    let fixture = try NativeBridgeFixture(.responds)
    defer { fixture.cleanup() }
    let bridge = NativeLockScreenWallpaperBridge(
        executableURL: fixture.executableURL,
        requestTimeout: 2.0
    )

    #expect(await awaitBridgeResult { bridge.prepare(completion: $0) })
    #expect(await awaitBridgeResult { bridge.showForLockTransition(completion: $0) })
    #expect(bridge.isReady)
    stopBridge(bridge, fixture: fixture)
}

@Test func nativeBridgeReportsProcessExitDuringRequest() async throws {
    let fixture = try NativeBridgeFixture(.exitsDuringRequest)
    defer { fixture.cleanup() }
    let bridge = NativeLockScreenWallpaperBridge(
        executableURL: fixture.executableURL,
        requestTimeout: 0.5
    )

    #expect(await awaitBridgeResult { bridge.prepare(completion: $0) } == false)
    #expect(bridge.isReady == false)
    stopBridge(bridge, fixture: fixture)
}

@Test func nativeBridgeTimesOutWhenProcessDoesNotRespond() async throws {
    let fixture = try NativeBridgeFixture(.doesNotRespond)
    defer { fixture.cleanup() }
    let bridge = NativeLockScreenWallpaperBridge(
        executableURL: fixture.executableURL,
        requestTimeout: 0.1
    )

    #expect(await awaitBridgeResult { bridge.prepare(completion: $0) } == false)
    #expect(bridge.isReady == false)
    stopBridge(bridge, fixture: fixture)
}

@Test func nativeBridgeIgnoresMalformedJSONUntilTimeout() async throws {
    let fixture = try NativeBridgeFixture(.sendsMalformedJSON)
    defer { fixture.cleanup() }
    let bridge = NativeLockScreenWallpaperBridge(
        executableURL: fixture.executableURL,
        requestTimeout: 0.1
    )

    #expect(await awaitBridgeResult { bridge.prepare(completion: $0) } == false)
    stopBridge(bridge, fixture: fixture)
}

@Test func nativeBridgeSurfacesPrepareError() async throws {
    let fixture = try NativeBridgeFixture(.rejectsPrepare)
    defer { fixture.cleanup() }
    let bridge = NativeLockScreenWallpaperBridge(
        executableURL: fixture.executableURL,
        requestTimeout: 0.5
    )

    #expect(await awaitBridgeResult { bridge.prepare(completion: $0) } == false)
    #expect(bridge.isReady == false)
    stopBridge(bridge, fixture: fixture)
}

@Test func nativeBridgeRetriesAfterProcessCrash() async throws {
    let fixture = try NativeBridgeFixture(.crashesOnce)
    defer { fixture.cleanup() }
    let bridge = NativeLockScreenWallpaperBridge(
        executableURL: fixture.executableURL,
        requestTimeout: 0.5
    )

    #expect(await awaitBridgeResult { bridge.prepare(completion: $0) } == false)
    #expect(await awaitBridgeResult { bridge.prepare(completion: $0) })
    #expect(bridge.isReady)
    stopBridge(bridge, fixture: fixture)
}

@Test func nativeBridgeIgnoresUnknownCallbackBeforeValidResponse() async throws {
    let fixture = try NativeBridgeFixture(.sendsUnknownResponseBeforeValidResponse)
    defer { fixture.cleanup() }
    let bridge = NativeLockScreenWallpaperBridge(
        executableURL: fixture.executableURL,
        requestTimeout: 0.5
    )

    #expect(await awaitBridgeResult { bridge.prepare(completion: $0) })
    #expect(bridge.isReady)
    stopBridge(bridge, fixture: fixture)
}
