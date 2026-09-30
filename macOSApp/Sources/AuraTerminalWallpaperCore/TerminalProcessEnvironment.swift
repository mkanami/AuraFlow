import Foundation

/// Finder/launchd do not supply the PATH or locale of an interactive terminal.
/// Use the same environment for preview and wallpaper sessions, including
/// interpreters selected by a script's /usr/bin/env shebang.
enum TerminalProcessEnvironment {
    static func make(
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        overrides: [String: String],
        executable: String,
        columns: Int,
        rows: Int
    ) -> [String: String] {
        var environment = inherited
        let executableDirectory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        let systemDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let companionDirectories = executable.hasPrefix("/") && !systemDirectories.contains(executableDirectory)
            ? [executableDirectory] : []
        let candidates = companionDirectories + ["/opt/homebrew/bin", "/usr/local/bin"]
            + (inherited["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        environment["PATH"] = candidates.filter {
            $0.hasPrefix("/") && seen.insert($0).inserted
        }.joined(separator: ":")

        let locale = ["LC_ALL", "LC_CTYPE", "LANG"]
            .compactMap { inherited[$0] }
            .first { !$0.isEmpty } ?? ""
        let isUTF8 = locale.lowercased().replacingOccurrences(of: "-", with: "").contains("utf8")
        if !isUTF8 {
            if let all = inherited["LC_ALL"], !all.isEmpty {
                environment["LC_ALL"] = "en_US.UTF-8"
            }
            environment["LC_CTYPE"] = "en_US.UTF-8"
            environment["LANG"] = "en_US.UTF-8"
        }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["COLUMNS"] = String(columns)
        environment["LINES"] = String(rows)
        environment["AURAFLOW_TERMINAL_WALLPAPER"] = "1"
        // An explicit per-command environment remains authoritative.
        environment.merge(overrides) { _, value in value }
        return environment
    }
}
