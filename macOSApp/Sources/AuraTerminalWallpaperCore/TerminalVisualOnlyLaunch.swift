import Foundation

/// Applied before the executable (including its library initializers) runs.
/// Descendants inherit the restrictions. This is an audio-only policy, not a
/// general security sandbox: filesystem and network access remain unchanged.
struct TerminalVisualOnlyLaunch {
    let executable: String
    let arguments: [String]

    // macOS ships this launcher, but its profile API is deprecated. Fail
    // closed if it is unavailable; never silently run a CLI with audio access.
    static let launcher = "/usr/bin/sandbox-exec"
    static let profile = #"""
    (version 1)
    (allow default)
    (deny device-microphone)
    (deny mach-lookup
        (global-name-regex #"^com[.]apple[.]audio([.]|$)")
        (global-name "com.apple.audiohald")
        (global-name "com.apple.coreservices.launchservicesd")
        (global-name "com.apple.lsd.open"))
    (deny iokit-open
        (iokit-user-client-class-regex #".*(Audio|audio).*"))
    ; Do not delegate sound playback to an existing, unrestricted GUI app.
    (deny appleevent-send)
    """#

    init(executable: String, arguments: [String],
         isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) throws {
        guard isExecutable(Self.launcher) else { throw TerminalPTYError.audioIsolationUnavailable }
        self.executable = Self.launcher
        // Separate argv elements: no shell interpretation or user-supplied
        // policy, even for custom commands, spaces and metacharacters.
        self.arguments = [Self.launcher, "-p", Self.profile, executable] + arguments
    }
}
