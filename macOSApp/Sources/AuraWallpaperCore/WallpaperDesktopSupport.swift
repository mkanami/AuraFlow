import AppKit
import Foundation

public enum WallpaperDesktopSupport {
    private static let backupNames = ["wallpaper_backup.json", "wallpaper_backup_original.json"]
    private static let wallpaperServiceProcessNames = [
        "WallpaperAgent",
        "wallpaperexportd",
        "WallpaperImageExtension",
        "WallpaperSequoiaExtension",
        "WallpaperLegacyExtension",
        "WallpaperDynamicExtension",
        "WallpaperAerialsExtension",
        "NeptuneOneWallpaper",
        "Dock"
    ]

    @discardableResult
    public static func captureCurrentDesktopWallpaperBackup(
        appSupportPath: String,
        systemWallpaperIndexURL: URL? = nil
    ) -> Bool {
        let systemWallpaperIndexURL = systemWallpaperIndexURL ?? defaultSystemWallpaperIndexURL()
        let managedPath = managedWallpaperPath(appSupportPath: appSupportPath)
        let workspace = NSWorkspace.shared
        var wallpapers: [String: String] = [:]
        let savedStore = saveWallpaperStoreBackupIfNeeded(
            appSupportPath: appSupportPath,
            systemWallpaperIndexURL: systemWallpaperIndexURL
        )

        for screen in NSScreen.screens {
            guard let url = workspace.desktopImageURL(for: screen) else { continue }
            let standardized = url.standardizedFileURL.path
            guard !standardized.isEmpty, standardized != managedPath else { continue }
            wallpapers[screenIdentifier(screen)] = standardized
        }

        guard !wallpapers.isEmpty else { return savedStore }
        return saveWallpaperBackup(appSupportPath: appSupportPath, wallpapers: wallpapers) || savedStore
    }

    @discardableResult
    public static func applyToAllDesktops(imagePath: String, retryCount: Int = 3) -> Bool {
        let standardizedPath = URL(fileURLWithPath: imagePath).standardized.path
        guard FileManager.default.fileExists(atPath: standardizedPath) else { return false }
        let escapedPath = escapeForAppleScript(standardizedPath)
        let scripts = [
            """
            tell application "System Events"
              repeat with d in desktops
                set picture of d to POSIX file "\(escapedPath)"
              end repeat
            end tell
            """,
            """
            tell application "System Events" to set picture of every desktop to POSIX file "\(escapedPath)"
            """,
            """
            tell application "Finder" to set desktop picture to POSIX file "\(escapedPath)"
            """
        ]

        let attempts = max(1, retryCount)
        for _ in 0..<attempts {
            for screen in NSScreen.screens {
                _ = try? NSWorkspace.shared.setDesktopImageURL(
                    URL(fileURLWithPath: standardizedPath),
                    for: screen,
                    options: [:]
                )
            }
            for script in scripts {
                _ = runAppleScript(script)
            }
            if allDesktopsMatch(path: standardizedPath) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return false
    }

    @discardableResult
    public static func restoreFromBackupFiles(
        appSupportPath: String,
        systemWallpaperIndexURL: URL? = nil
    ) -> Bool {
        let systemWallpaperIndexURL = systemWallpaperIndexURL ?? defaultSystemWallpaperIndexURL()
        if restoreWallpaperStoreBackup(
            appSupportPath: appSupportPath,
            systemWallpaperIndexURL: systemWallpaperIndexURL
        ) {
            return true
        }

        guard let wallpapers = loadWallpaperBackup(appSupportPath: appSupportPath) else { return false }
        let fallbackPath = wallpapers.values.first
        let workspace = NSWorkspace.shared
        var appliedAny = false
        var appliedPathForAllDesktops: String?

        for screen in NSScreen.screens {
            let identifier = screenIdentifier(screen)
            guard let imagePath = wallpapers[identifier] ?? fallbackPath else { continue }
            let standardized = URL(fileURLWithPath: imagePath).standardized.path
            guard FileManager.default.fileExists(atPath: standardized) else { continue }
            let url = URL(fileURLWithPath: standardized)
            if (try? workspace.setDesktopImageURL(url, for: screen, options: [:])) != nil {
                appliedAny = true
                if appliedPathForAllDesktops == nil {
                    appliedPathForAllDesktops = standardized
                }
            }
        }

        guard appliedAny, let path = appliedPathForAllDesktops else { return false }
        return applyToAllDesktops(imagePath: path)
    }

    private static func loadWallpaperBackup(appSupportPath: String) -> [String: String]? {
        let managedPath = managedWallpaperPath(appSupportPath: appSupportPath)
        for fileName in backupNames {
            let path = (appSupportPath as NSString).appendingPathComponent(fileName)
            guard
                let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                let object = try? JSONSerialization.jsonObject(with: data),
                let dictionary = object as? [String: Any]
            else {
                continue
            }

            let parsed = dictionary.reduce(into: [String: String]()) { result, item in
                guard let value = item.value as? String, !value.isEmpty else { return }
                let standardized = URL(fileURLWithPath: value).standardized.path
                if standardized == managedPath {
                    return
                }
                result[item.key] = standardized
            }

            if !parsed.isEmpty {
                return parsed
            }
        }
        return nil
    }

    @discardableResult
    public static func saveWallpaperBackup(appSupportPath: String, wallpapers: [String: String]) -> Bool {
        let managedPath = managedWallpaperPath(appSupportPath: appSupportPath)
        let sanitized = wallpapers.reduce(into: [String: String]()) { result, item in
            let standardized = URL(fileURLWithPath: item.value).standardizedFileURL.path
            guard !standardized.isEmpty, standardized != managedPath else { return }
            result[item.key] = standardized
        }

        guard !sanitized.isEmpty else { return false }

        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: appSupportPath, isDirectory: true),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys])
            for fileName in backupNames {
                let path = (appSupportPath as NSString).appendingPathComponent(fileName)
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public static func saveWallpaperStoreBackupIfNeeded(
        appSupportPath: String,
        systemWallpaperIndexURL: URL? = nil
    ) -> Bool {
        let systemWallpaperIndexURL = systemWallpaperIndexURL ?? defaultSystemWallpaperIndexURL()
        let sourceURL = systemWallpaperIndexURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return false }
        let backupURL = wallpaperStoreBackupURL(appSupportPath: appSupportPath)

        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: appSupportPath, isDirectory: true),
                withIntermediateDirectories: true
            )

            let sourceData = try Data(contentsOf: sourceURL)
            if let existingData = try? Data(contentsOf: backupURL), existingData == sourceData {
                return true
            }

            try sourceData.write(to: backupURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public static func restoreWallpaperStoreBackup(
        appSupportPath: String,
        systemWallpaperIndexURL: URL? = nil
    ) -> Bool {
        let systemWallpaperIndexURL = systemWallpaperIndexURL ?? defaultSystemWallpaperIndexURL()
        let backupURL = wallpaperStoreBackupURL(appSupportPath: appSupportPath)
        guard FileManager.default.fileExists(atPath: backupURL.path) else { return false }

        do {
            try FileManager.default.createDirectory(
                at: systemWallpaperIndexURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let backupData = try Data(contentsOf: backupURL)
            try backupData.write(to: systemWallpaperIndexURL, options: .atomic)
            reloadWallpaperServices()
            return true
        } catch {
            return false
        }
    }

    private static func runAppleScript(_ source: String) -> (success: Bool, output: String?) {
        guard let script = NSAppleScript(source: source) else {
            return (false, nil)
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil {
            return (false, nil)
        }
        return (true, result.stringValue)
    }

    private static func allDesktopsMatch(path: String) -> Bool {
        let escapedPath = escapeForAppleScript(path)
        let verificationScript = """
        tell application "System Events"
          set targetPath to POSIX path of (POSIX file "\(escapedPath)")
          repeat with d in desktops
            try
              set currentPath to POSIX path of (picture of d)
              if currentPath is not targetPath then
                return "mismatch"
              end if
            on error
              return "mismatch"
            end try
          end repeat
          return "ok"
        end tell
        """
        let result = runAppleScript(verificationScript)
        return result.success && result.output?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }

    private static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func reloadWallpaperServices() {
        for processName in wallpaperServiceProcessNames {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = [processName]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }
    }

    private static func screenIdentifier(_ screen: NSScreen) -> String {
        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        if let number = screenNumber as? NSNumber {
            return number.stringValue
        }
        return String(describing: ObjectIdentifier(screen))
    }

    private static func managedWallpaperPath(appSupportPath: String) -> String {
        let managedPath = (appSupportPath as NSString).appendingPathComponent("last_frame.png")
        return URL(fileURLWithPath: managedPath).standardized.path
    }

    private static func wallpaperStoreBackupURL(appSupportPath: String) -> URL {
        URL(fileURLWithPath: appSupportPath, isDirectory: true)
            .appendingPathComponent("wallpaper_store_backup.plist")
    }

    private static func defaultSystemWallpaperIndexURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }
}
