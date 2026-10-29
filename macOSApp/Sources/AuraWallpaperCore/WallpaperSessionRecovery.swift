import Darwin
import Foundation

/// Independent of the app's launch-at-login preference. This short-lived job
/// restores native user wallpaper routes when playback did not start or died.
public final class WallpaperSessionRecovery {
    public enum Result: Equatable { case notNeeded, runtimeActive, deferred, restored }

    private let store: WallpaperRuntimeStore
    private let wallpaperStoreURL: URL
    private let screenSaverURL: URL
    private let runtimeIsLive: () -> Bool
    private let sessionIsLocked: () -> Bool?
    private let wait: (TimeInterval) -> Void
    private let requestAutostart: () -> Void
    private let sessionIdentifier: () -> String?
    private let suspendNative: (() -> Bool) throws -> Bool
    private let refresh: (() throws -> Void) throws -> Void

    public init(
        store: WallpaperRuntimeStore = WallpaperRuntimeStore(),
        wallpaperStoreURL: URL = WallpaperPlatformConstants.wallpaperStoreURL(homeURL: FileManager.default.homeDirectoryForCurrentUser),
        runtimeIsLive: (() -> Bool)? = nil,
        sessionIsLocked: @escaping () -> Bool? = { LockScreenSession.currentIsLocked() },
        wait: @escaping (TimeInterval) -> Void = Thread.sleep,
        requestAutostart: (() -> Void)? = nil,
        suspendNative: ((() -> Bool) throws -> Bool)? = nil,
        refresh: ((() throws -> Void) throws -> Void)? = nil,
        sessionIdentifier: @escaping () -> String? = { LockScreenSession.currentIdentifier() },
        screenSaverURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Screen Savers/AuraFlowLockScreen.saver")
    ) {
        self.store = store
        self.wallpaperStoreURL = wallpaperStoreURL
        self.screenSaverURL = screenSaverURL
        let live = runtimeIsLive ?? { Self.runtimeIsLive(in: store) }
        self.runtimeIsLive = live
        self.sessionIsLocked = sessionIsLocked
        self.wait = wait
        self.sessionIdentifier = sessionIdentifier
        self.requestAutostart = requestAutostart ?? {
            let runtime = store.appSupportURL.appendingPathComponent("Runtime")
            let helper = runtime.appendingPathComponent("AuraWallpaperAgent")
            let bridge = runtime.appendingPathComponent("AuraWallpaperNativeBridge")
            guard FileManager.default.isExecutableFile(atPath: helper.path) else { return }
            // Recover a missing registration or wake a waiting launchd job
            // before falling back. This path does not require the GUI to open.
            try? AutostartManager(store: store, helperURL: helper,
                nativeBridgeURL: FileManager.default.isExecutableFile(atPath: bridge.path) ? bridge : nil)
                .migrateExistingLaunchAgentIfNeeded()
        }
        self.suspendNative = suspendNative ?? { shouldProceed in
            let installer = AerialLockScreenInstaller(
                wallpaperStoreURL: wallpaperStoreURL,
                stateDirectoryURL: store.appSupportURL.appendingPathComponent("ModernLockScreen")
            )
            return try installer.suspendInactiveSession(shouldProceed: shouldProceed)
        }
        self.refresh = refresh ?? { commit in
            try commit()
            // The store is observed by WallpaperAgent. Keep a live owner in
            // place: restarting it can race an automatic lock and turn the
            // secure surface black. Only launch it when it is absent.
            try AerialProviderController.prewarmLockScreenProvider(
                shouldProceed: { sessionIsLocked() == false && !live() }
            )
        }
    }

    @discardableResult
    public func reconcile(autostartGracePeriod: TimeInterval = 10, installationGracePeriod: TimeInterval = 5) throws -> Result {
        let config = store.loadConfig()
        let hasMediaAutostart = WallpaperLoginSelection.enabled(in: store)
            && !config.isAutostartDeferred(in: sessionIdentifier())
            && WallpaperLoginSelection.hasSource(in: store, runtime: WallpaperLoginSelection.runtime(in: store))
        guard hasManagedInstallation || hasMediaAutostart else { return .notNeeded }
        guard !runtimeIsLive() else { return .runtimeActive }
        guard sessionIsLocked() != nil else { return .deferred }
        // Lock-only installs commit their route before launching their helper.
        // A recovery tick in that small handoff must not invalidate Apply's
        // confirmation. Old journals after a reboot have no such grace lease.
        if managedFiles.contains(where: { url in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate else { return false }
            let age = Date().timeIntervalSince(modified)
            return age >= 0 && age < installationGracePeriod
        }) { return .deferred }
        if autostartRequested {
            requestAutostart()
            if runtimeIsLive() { return .runtimeActive }
            // launchd may start this job before the selected playback helper.
            // Wait for it, while leaving the saved native installation intact.
            var remaining = max(0, autostartGracePeriod)
            while remaining > 0 {
                let interval = min(0.5, remaining)
                wait(interval)
                if runtimeIsLive() { return .runtimeActive }
                if sessionIsLocked() != false { return .deferred }
                remaining -= interval
            }
        }
        guard canRestore else { return .deferred }
        guard try suspendRoutes() else { return .notNeeded }
        // Reassert if an independently exiting system owner flushed a stale
        // selection, then ensure a wallpaper owner is available.
        try refresh { _ = try? suspendRoutes() }
        return .restored
    }

    private var canRestore: Bool { sessionIsLocked() == false && !runtimeIsLive() }

    private var saverJournals: [URL] {
        ["terminal-wallpaper", "wallpaper-engine/runtime"].map {
            store.appSupportURL.appendingPathComponent($0)
                .appendingPathComponent("screen-saver-wallpaper-store-backup.json")
        }
    }

    private var hasManagedInstallation: Bool {
        managedFiles.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var managedFiles: [URL] {
        saverJournals + [store.appSupportURL.appendingPathComponent("ModernLockScreen/installation.json")]
    }

    private var autostartRequested: Bool {
        let config = store.loadConfig()
        return WallpaperLoginSelection.enabled(in: store)
            && !config.isAutostartDeferred(in: sessionIdentifier())
            && config.login_wallpaper_runtime != .removed
    }

    private func suspendRoutes() throws -> Bool {
        guard canRestore else { return false }
        var changed = false
        var firstError: Error?
        do { changed = try suspendNative { self.canRestore } }
        catch { firstError = error }
        for journal in saverJournals {
            let recovery = ScreenSaverRouteRecovery(storeURL: wallpaperStoreURL, journalURL: journal, saverURL: screenSaverURL)
            do {
                if try recovery.suspendIfNeeded(shouldProceed: { self.canRestore }) { changed = true }
            } catch { firstError = firstError ?? error }
        }
        if !changed, let firstError { throw firstError }
        return changed
    }

    private static func runtimeIsLive(in store: WallpaperRuntimeStore) -> Bool {
        if store.daemonProcessStatus.isOwned,
           let source = store.effectiveLockScreenSourceURL(for: store.loadConfig()),
           FileManager.default.fileExists(atPath: source.path) { return true }
        if WallpaperLoginSelection.terminalRuntimeIsLive(in: store) { return true }
        for (path, name) in [
            ("wallpaper-engine/runtime/agent.pid", "AuraWebWallpaperAgent"),
        ] {
            guard let text = try? String(contentsOf: store.appSupportURL.appendingPathComponent(path)),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
                  kill(pid, 0) == 0 || errno == EPERM else { continue }
            var executable = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &executable, UInt32(executable.count)) > 0,
               URL(fileURLWithPath: String(cString: executable)).lastPathComponent == name { return true }
        }
        return false
    }
}

public enum WallpaperSessionRecoveryRegistration {
    public static let label = "com.andrijvergeles.auraflow.session-recovery"

    public static func install(
        helperURL: URL,
        launchAgentURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist"),
        launchctl: LaunchctlRunner? = nil
    ) throws {
        let launchctl = launchctl ?? LaunchAgentManager.executeLaunchctl
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helperURL.path, "--recover-wallpaper-session"],
            "RunAtLoad": true,
            "StartInterval": 30,
            "ProcessType": "Background",
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: launchAgentURL, options: .atomic)
        let service = "gui/\(getuid())/\(label)"
        if !launchctl(["print", service]).succeeded {
            let result = launchctl(["bootstrap", "gui/\(getuid())", launchAgentURL.path])
            guard result.succeeded else { throw WallpaperRuntimeError.unavailable(result.output) }
        }
    }
}
