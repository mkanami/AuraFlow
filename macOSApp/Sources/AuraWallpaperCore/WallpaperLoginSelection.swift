import Foundation
import Darwin

/// One application preference and one applied engine. Preview presets never
/// select the login engine. Legacy installs are inferred from saved sources.
public enum WallpaperLoginSelection {
    public static let terminalLabel = "com.andrijvergeles.auraflow.terminal-wallpaper"

    public static func runtime(in store: WallpaperRuntimeStore) -> WallpaperLoginRuntime {
        let config = store.loadConfig()
        if let selected = config.login_wallpaper_runtime { return selected }
        if !config.video_path.isEmpty { return .video }
        if store.effectiveLockScreenSourceURL(for: config).map({ FileManager.default.fileExists(atPath: $0.path) }) == true { return .video }
        if terminalConfiguration(in: store) != nil { return .terminal }
        return .removed
    }

    public static func terminalConfiguration(in store: WallpaperRuntimeStore) -> [String: Any]? {
        let url = store.appSupportURL.appendingPathComponent("terminal-wallpaper/config.json")
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = config["command"] as? [String: Any],
              let executable = command["executable"] as? String, !executable.isEmpty else { return nil }
        return config
    }

    public static func hasSource(in store: WallpaperRuntimeStore, runtime: WallpaperLoginRuntime) -> Bool {
        switch runtime {
        case .video:
            return store.effectiveLockScreenSourceURL(for: store.loadConfig()).map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false
        case .terminal:
            guard let config = terminalConfiguration(in: store),
                  let command = config["command"] as? [String: Any],
                  let executable = command["executable"] as? String else { return false }
            return FileManager.default.isExecutableFile(atPath: executable)
        case .removed: return false
        }
    }

    public static func enabled(in store: WallpaperRuntimeStore) -> Bool {
        let config = store.loadConfig()
        if config.login_wallpaper_runtime != nil { return config.autostart == true }
        if runtime(in: store) == .video { return config.autostart == true }
        let behavior = terminalConfiguration(in: store)?["behavior"] as? [String: Any]
        return config.autostart == true || behavior?["launchAtLogin"] as? Bool == true
    }

    public static func terminalLaunchAgentURL(in store: WallpaperRuntimeStore) -> URL {
        store.launchAgentURL.deletingLastPathComponent().appendingPathComponent(terminalLabel + ".plist")
    }

    static func terminalRuntimeIsLive(in store: WallpaperRuntimeStore) -> Bool {
        let root = store.appSupportURL.appendingPathComponent("terminal-wallpaper")
        guard let text = try? String(contentsOf: root.appendingPathComponent("agent.pid")),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
              kill(pid, 0) == 0 || errno == EPERM else { return false }
        let identityURL = root.appendingPathComponent("agent-identity.json")
        if FileManager.default.fileExists(atPath: identityURL.path) {
            // An atomic app update can unlink the executable of a healthy
            // running helper. Its saved PID/start identity remains valid even
            // when proc_pidpath cannot resolve that former executable vnode.
            guard let data = try? Data(contentsOf: identityURL),
                  let identity = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (identity["pid"] as? NSNumber)?.int32Value == pid,
                  let start = (identity["startTimeMicros"] as? NSNumber)?.uint64Value else { return false }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size
                && info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec == start
        }
        // Legacy helpers have no start identity. They still need a matching
        // executable path so a PID reused after reboot cannot claim ownership.
        var path = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &path, UInt32(path.count)) > 0 &&
            URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
                .lastPathComponent == "AuraTerminalWallpaperAgent"
    }

    public static func registerTerminal(in store: WallpaperRuntimeStore, helperURL: URL, launchAgentURL: URL? = nil) throws {
        let url = launchAgentURL ?? terminalLaunchAgentURL(in: store)
        let plist: [String: Any] = ["Label": terminalLabel,
            "ProgramArguments": [helperURL.path, "--config", store.appSupportURL.appendingPathComponent("terminal-wallpaper/config.json").path],
            "RunAtLoad": true, "KeepAlive": false, "LimitLoadToSessionType": "Aqua"]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url, options: .atomic)
    }

    public static func removeRegistration(at url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile {}
    }
}
