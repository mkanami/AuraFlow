import Darwin
import Foundation

internal enum AerialLockScreenOperationAbort: Error {
    case sessionChanged
    case storeChanged
}

internal final class AerialProviderController {
    internal typealias ConditionalSystemAction =
        (_ shouldProceed: () -> Bool) throws -> Void

    internal static func refreshWallpaperProcesses(
        shouldProceed: () -> Bool
    ) throws {
        for (executable, arguments) in [
            (
                "/usr/bin/pkill",
                ["-x", WallpaperPlatformConstants.aerialExtensionProcessName]
            ),
            ("/usr/bin/pkill", ["-x", "legacyScreenSaver"]),
            (
                "/usr/bin/killall",
                [WallpaperPlatformConstants.wallpaperAgentProcessName]
            ),
            ("/usr/bin/killall", [WallpaperPlatformConstants.dockProcessName]),
        ] {
            guard shouldProceed() else {
                throw AerialLockScreenOperationAbort.sessionChanged
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                continue
            }
        }
    }

    /// Reloads only the process that owns the Desktop wallpaper provider.
    ///
    /// Shared Remove uses this after restoring a safe pre-Aura store and
    /// before asking NSWorkspace to select the user's latest image. Restarting
    /// Dock here produces a grey Desktop flash, while restarting every Aerial
    /// helper is unnecessary once the original asset is already back on disk.
    internal static func refreshDesktopWallpaperProvider(
        prepareForLaunch: () throws -> Void,
        shouldProceed: () -> Bool
    ) throws {
        guard shouldProceed() else {
            throw AerialLockScreenOperationAbort.sessionChanged
        }
        let previousProviderPIDs = processIdentifiers(
            named: WallpaperPlatformConstants.aerialExtensionProcessName
        )
        let previousOwnerPIDs = processIdentifiers(
            named: WallpaperPlatformConstants.wallpaperAgentProcessName
        )

        runProcess(
            "/usr/bin/killall",
            [WallpaperPlatformConstants.wallpaperAgentProcessName]
        )
        guard shouldProceed() else {
            throw AerialLockScreenOperationAbort.sessionChanged
        }
        guard waitForProcessesToExit(
            previousProviderPIDs.union(previousOwnerPIDs),
            timeout: 2.0
        ) else {
            throw AerialLockScreenInstallerError
                .aerialProviderRestartFailed
        }
        // The old WallpaperAgent can rewrite Index.plist while exiting. The
        // caller therefore commits the complete Files-backed image route only
        // after every old owner/provider process is gone and before the new
        // owner is launched.
        try prepareForLaunch()
        guard shouldProceed() else {
            throw AerialLockScreenOperationAbort.sessionChanged
        }
        runProcess(
            "/usr/bin/open",
            [
                "-gja",
                WallpaperPlatformConstants.wallpaperAgentApplicationPath,
            ]
        )
        guard waitForFreshWallpaperRuntime(
            excludingProviders: previousProviderPIDs,
            excludingOwners: previousOwnerPIDs
        ) else {
            throw AerialLockScreenInstallerError
                .aerialProviderRestartFailed
        }
    }

    private static func waitForProcessesToExit(
        _ processIDs: Set<Int32>,
        timeout: TimeInterval
    ) -> Bool {
        guard !processIDs.isEmpty else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let liveProcessIDs = processIDs.filter { processID in
                Darwin.kill(processID, 0) == 0 || errno == EPERM
            }
            if liveProcessIDs.isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }

    internal static func refreshLockScreenProvider(
        shouldProceed: () -> Bool
    ) throws {
        guard shouldProceed() else {
            throw AerialLockScreenOperationAbort.sessionChanged
        }
        let previousProviderPIDs = processIdentifiers(
            named: WallpaperPlatformConstants.aerialExtensionProcessName
        )
        let previousOwnerPIDs = processIdentifiers(
            named: WallpaperPlatformConstants.wallpaperAgentProcessName
        )
        guard shouldProceed() else {
            throw AerialLockScreenOperationAbort.sessionChanged
        }

        // Restart the owner, not the extension by itself. ExtensionKit does
        // not reliably relaunch an orphaned provider on the next lock, which
        // produces a black screen. WallpaperAgent immediately creates a fresh
        // provider with a new state machine.
        runProcess(
            "/usr/bin/killall",
            [WallpaperPlatformConstants.wallpaperAgentProcessName]
        )
        // WallpaperAgent is the owner of the ExtensionKit provider. Wait for
        // that owner to leave before touching the provider itself; the
        // extension can legitimately outlive its owner for a short time and
        // must not make every first Lock fail just because its old PID is
        // still draining.
        guard waitForProcessesToExit(
            previousOwnerPIDs,
            timeout: 2.0
        ) else {
            throw AerialLockScreenInstallerError
                .aerialProviderRestartFailed
        }

        guard shouldProceed() else {
            throw AerialLockScreenOperationAbort.sessionChanged
        }
        // A stale ExtensionKit instance can retain the previous Aerial asset
        // after its owner has gone away. Kill only that provider and give it a
        // short bounded drain window. This never touches Dock or Desktop
        // wallpaper windows.
        runProcess(
            "/usr/bin/pkill",
            ["-x", WallpaperPlatformConstants.aerialExtensionProcessName]
        )
        _ = waitForProcessesToExit(previousProviderPIDs, timeout: 1.0)

        runProcess(
            "/usr/bin/open",
            [
                "-gja",
                WallpaperPlatformConstants.wallpaperAgentApplicationPath,
            ]
        )
        guard waitForFreshWallpaperRuntime(
            excludingProviders: previousProviderPIDs,
            excludingOwners: previousOwnerPIDs
        ) else {
            throw AerialLockScreenInstallerError
                .aerialProviderRestartFailed
        }
    }

    /// Keeps an already-installed provider warm without killing it. This is
    /// used while the user is unlocked, when the Desktop route must remain
    /// untouched. The lock handoff also keeps the existing provider alive;
    /// the route promotion is written directly to the store before loginwindow
    /// resolves the secure Lock Screen.
    internal static func prewarmLockScreenProvider(
        shouldProceed: () -> Bool
    ) throws {
        guard shouldProceed() else {
            throw AerialLockScreenOperationAbort.sessionChanged
        }

        let currentProviderPIDs = processIdentifiers(
            named: WallpaperPlatformConstants.aerialExtensionProcessName
        )
        if !currentProviderPIDs.isEmpty
            || !processIdentifiers(
                named: WallpaperPlatformConstants.wallpaperAgentProcessName
            ).isEmpty {
            return
        }

        runProcess(
            "/usr/bin/open",
            [
                "-gja",
                WallpaperPlatformConstants.wallpaperAgentApplicationPath,
            ]
        )
        guard waitForWallpaperRuntime() else {
            throw AerialLockScreenInstallerError
                .aerialProviderRestartFailed
        }
    }

    internal static func waitForFreshWallpaperRuntime(
        excludingProviders previousProviderPIDs: Set<Int32>,
        excludingOwners previousOwnerPIDs: Set<Int32>
    ) -> Bool {
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            let currentProviderPIDs = processIdentifiers(
                named: WallpaperPlatformConstants.aerialExtensionProcessName
            )
            if !currentProviderPIDs.isEmpty,
               currentProviderPIDs.isDisjoint(with: previousProviderPIDs) {
                return true
            }
            let currentOwnerPIDs = processIdentifiers(
                named: WallpaperPlatformConstants.wallpaperAgentProcessName
            )
            if !currentOwnerPIDs.isEmpty,
               currentOwnerPIDs.isDisjoint(with: previousOwnerPIDs) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    internal static func waitForWallpaperRuntime() -> Bool {
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if !processIdentifiers(
                named: WallpaperPlatformConstants.aerialExtensionProcessName
            ).isEmpty
                || !processIdentifiers(
                    named: WallpaperPlatformConstants.wallpaperAgentProcessName
                ).isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    internal static func waitForProcessExit(
        _ process: Process,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.isRunning else { return true }
        process.terminate()
        return false
    }

    internal static func processIdentifiers(named name: String) -> Set<Int32> {
        // This method is called by the agent's main-thread health timer. A
        // child `pgrep` plus a timeout can stall that run loop while
        // WallpaperAgent is starting, exactly when loginwindow needs the
        // prepared Lock Screen route. Enumerate process paths directly so a
        // health sample is bounded by the kernel query rather than another
        // process launch and wait.
        let bufferSize = proc_listallpids(nil, 0)
        guard bufferSize > 0 else { return [] }
        var pids = [pid_t](
            repeating: 0,
            count: Int(bufferSize) / MemoryLayout<pid_t>.stride
        )
        let bytesUsed = proc_listallpids(
            &pids,
            bufferSize
        )
        guard bytesUsed > 0 else { return [] }

        var matches = Set<Int32>()
        let pidCount = min(
            Int(bytesUsed) / MemoryLayout<pid_t>.stride,
            pids.count
        )
        for pid in pids.prefix(pidCount) where pid > 0 {
            var path = [Int8](repeating: 0, count: 4_096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
                continue
            }
            let pathBytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            guard URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self))
                .lastPathComponent == name
            else {
                continue
            }
            matches.insert(Int32(pid))
        }
        return matches
    }

    internal static func runProcess(
        _ executable: String,
        _ arguments: [String]
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            _ = waitForProcessExit(process, timeout: 1.0)
        } catch {
            return
        }
    }
}
