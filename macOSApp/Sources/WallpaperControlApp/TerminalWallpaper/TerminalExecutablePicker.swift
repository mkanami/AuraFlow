import AppKit

enum TerminalExecutablePicker {
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Terminal Executable"
        panel.message = "Choose an executable or an app bundle containing a terminal-compatible executable."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
