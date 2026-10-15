import AuraTerminalWallpaperCore

/// Main-thread state of the current child, independent of its PID lifetime.
/// Successful one-shot commands remain valid wallpaper sources after EOF.
struct TerminalOutputPublicationState {
    private(set) var hasContent = false
    private(set) var exitCode: Int32?

    mutating func receive(_ snapshot: TerminalGridSnapshot) {
        hasContent = snapshot.hasVisibleContent
    }

    mutating func finish(_ code: Int32) {
        exitCode = code
    }

    func canPublish(childRunning: Bool) -> Bool {
        hasContent && (exitCode == 0 || (exitCode == nil && childRunning))
    }

    var error: String? {
        guard let exitCode else { return nil }
        if exitCode != 0 { return "The terminal program exited with status \(exitCode)." }
        return hasContent ? nil : "The terminal program completed without visible output."
    }
}
