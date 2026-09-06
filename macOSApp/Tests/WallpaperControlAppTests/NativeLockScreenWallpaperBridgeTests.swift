import Foundation
import Testing
@testable import AuraWallpaperCore
@testable import AuraWallpaperAgent

private enum NativeBridgeFixtureMode {
    case responds
    case exitsDuringRequest
    case doesNotRespond
    case sendsMalformedJSON
    case rejectsPrepare
    case delayedPrepare
    case crashesOnce
    case sendsUnknownResponseBeforeValidResponse
    case incompatibleProtocolVersion
    case incompatibleArchitecture
    case incompatibleSymbols
    case missingCapabilities
}

private final class NativeBridgeFixture {
    let root: URL
    let executableURL: URL
    let markerURL: URL
    let releaseURL: URL

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
        markerURL = root.appendingPathComponent("first-process.marker")
        releaseURL = root.appendingPathComponent("release-prepare.marker")
        let script = Self.script(
            for: mode,
            markerURL: markerURL,
            releaseURL: releaseURL
        )
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
        markerURL: URL,
        releaseURL: URL
    ) -> String {
        let marker = shellQuote(markerURL.path)
        let release = shellQuote(releaseURL.path)
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
        case .delayedPrepare:
            return responseLoop(
                preparePrefix:
                    ": > \(marker); while [ ! -e \(release) ]; do sleep 0.01; done; ",
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
              if [ "$action" = "capabilities" ]; then
                printf '{"id":"stale-response","action":"capabilities","succeeded":true}\\n'
                printf '{"id":"%s","action":"capabilities","succeeded":true,"capabilities":{"protocolVersion":1,"architecture":"\(NativeLockScreenBridgeRuntimeCapabilities.currentArchitecture)","privateFrameworksLoaded":true,"requiredSymbolsResolved":true,"supportedActions":["capabilities","prepare","show","hide","pause","resume","shutdown"]}}\\n' "$id"
              else
                printf '{"id":"stale-response","action":"%s","succeeded":true}\\n' "$action"
                printf '{"id":"%s","action":"%s","succeeded":true}\\n' "$id" "$action"
              fi
              if [ "$action" = "shutdown" ]; then exit 0; fi
            done
            """
        case .incompatibleProtocolVersion:
            return responseLoop(capabilityProtocolVersion: 999, exitOnShutdown: true)
        case .incompatibleArchitecture:
            return responseLoop(
                capabilityArchitecture: "incompatible-architecture",
                exitOnShutdown: true
            )
        case .incompatibleSymbols:
            return responseLoop(
                privateFrameworksLoaded: false,
                requiredSymbolsResolved: false,
                exitOnShutdown: true
            )
        case .missingCapabilities:
            return responseLoop(includeCapabilities: false, exitOnShutdown: true)
        }
    }

    private static func responseLoop(
        prepareSucceeded: Bool = true,
        prepareError: String? = nil,
        capabilityProtocolVersion: Int = 1,
        capabilityArchitecture: String = NativeLockScreenBridgeRuntimeCapabilities
            .currentArchitecture,
        privateFrameworksLoaded: Bool = true,
        requiredSymbolsResolved: Bool = true,
        includeCapabilities: Bool = true,
        prepareDelay: TimeInterval? = nil,
        preparePrefix: String = "",
        exitOnShutdown: Bool
    ) -> String {
        let escapedError = prepareError.map(shellQuote) ?? "''"
        let capabilitiesResponse: String
        if includeCapabilities {
            let frameworksLoaded = privateFrameworksLoaded ? "true" : "false"
            let symbolsResolved = requiredSymbolsResolved ? "true" : "false"
            capabilitiesResponse = "printf '{\"id\":\"%s\",\"action\":\"capabilities\",\"succeeded\":true,\"capabilities\":{\"protocolVersion\":\(capabilityProtocolVersion),\"architecture\":\"\(capabilityArchitecture)\",\"privateFrameworksLoaded\":\(frameworksLoaded),\"requiredSymbolsResolved\":\(symbolsResolved),\"supportedActions\":[\"capabilities\",\"prepare\",\"show\",\"hide\",\"pause\",\"resume\",\"shutdown\"]}}\\n' \"$id\""
        } else {
            capabilitiesResponse = "printf '{\"id\":\"%s\",\"action\":\"capabilities\",\"succeeded\":true}\\n' \"$id\""
        }
        let prepareDelayCommand = prepareDelay.map { "sleep \($0); " } ?? ""
        var prepareResponse = ""
        if prepareSucceeded {
            prepareResponse = preparePrefix + prepareDelayCommand
                + "printf '{\"id\":\"%s\",\"action\":\"%s\",\"succeeded\":true}\\n' \"$id\" \"$action\""
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
          if [ "$action" = "capabilities" ]; then
            \(capabilitiesResponse)
          elif [ "$action" = "prepare" ]; then
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

@Test func nativeBridgeHideDoesNotLaunchStoppedProcess() async throws {
    let fixture = try NativeBridgeFixture(.responds)
    defer { fixture.cleanup() }
    let bridge = NativeLockScreenWallpaperBridge(
        executableURL: fixture.executableURL,
        requestTimeout: 0.5
    )

    bridge.hideAfterUnlock()
    try await Task.sleep(nanoseconds: 250_000_000)

    #expect(bridge.isReady == false)
}

@Test func nativeBridgeHideCancelsShowQueuedBehindPreparation() async throws {
    let fixture = try NativeBridgeFixture(.delayedPrepare)
    defer { fixture.cleanup() }
    let bridge = NativeLockScreenWallpaperBridge(
        executableURL: fixture.executableURL,
        requestTimeout: 1.0
    )
    let prepareMarkerURL = fixture.markerURL
    let prepareReleaseURL = fixture.releaseURL

    let shown = await withCheckedContinuation { continuation in
        // Enqueue show before scheduling hide. Using `async let` here made
        // the test itself racy because the child task could start only after
        // hide had already advanced the presentation generation.
        bridge.showForLockTransition { succeeded in
            continuation.resume(returning: succeeded)
        }
        Task {
            var attempts = 0
            while attempts < 200,
                  !FileManager.default.fileExists(
                    atPath: prepareMarkerURL.path
                  ) {
                attempts += 1
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            bridge.hideAfterUnlock()
            try? Data().write(to: prepareReleaseURL, options: .atomic)
        }
    }

    #expect(shown == false)
    stopBridge(bridge, fixture: fixture)
}

@Test func nativeBridgeRejectsIncompatibleProtocolVersion() async throws {
    let fixture = try NativeBridgeFixture(.incompatibleProtocolVersion)
    defer { fixture.cleanup() }
    let bridge = NativeLockScreenWallpaperBridge(
        executableURL: fixture.executableURL,
        requestTimeout: 0.5
    )

    #expect(await awaitBridgeResult { bridge.prepare(completion: $0) } == false)
    #expect(bridge.isReady == false)
    stopBridge(bridge, fixture: fixture)
}

@Test func nativeBridgeRejectsIncompatibleArchitecture() async throws {
    let fixture = try NativeBridgeFixture(.incompatibleArchitecture)
    defer { fixture.cleanup() }
    let bridge = NativeLockScreenWallpaperBridge(
        executableURL: fixture.executableURL,
        requestTimeout: 0.5
    )

    #expect(await awaitBridgeResult { bridge.prepare(completion: $0) } == false)
    #expect(bridge.isReady == false)
    stopBridge(bridge, fixture: fixture)
}

@Test func nativeBridgeRejectsIncompatiblePrivateFrameworkSymbols() async throws {
    let fixture = try NativeBridgeFixture(.incompatibleSymbols)
    defer { fixture.cleanup() }
    let bridge = NativeLockScreenWallpaperBridge(
        executableURL: fixture.executableURL,
        requestTimeout: 0.5
    )

    #expect(await awaitBridgeResult { bridge.prepare(completion: $0) } == false)
    #expect(bridge.isReady == false)
    stopBridge(bridge, fixture: fixture)
}

@Test func nativeBridgeDoesNotBecomeReadyWithoutCapabilities() async throws {
    let fixture = try NativeBridgeFixture(.missingCapabilities)
    defer { fixture.cleanup() }
    let bridge = NativeLockScreenWallpaperBridge(
        executableURL: fixture.executableURL,
        requestTimeout: 0.5
    )

    #expect(await awaitBridgeResult { bridge.prepare(completion: $0) } == false)
    #expect(bridge.isReady == false)
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
        // The fixture intentionally performs several shell parses before its
        // response. Keep this test deterministic when Swift Testing runs the
        // native-process tests concurrently on a loaded CI worker.
        requestTimeout: 2.0
    )

    #expect(await awaitBridgeResult { bridge.prepare(completion: $0) })
    #expect(bridge.isReady)
    stopBridge(bridge, fixture: fixture)
}
