import AppKit
import AuraWallpaperEngineCore

struct WallpaperEngineLocationPanelRequest {
    let directory: URL?
    let importing: Bool
}

/// AppKit owns only the native dialogs; discovery and persisted selection belong to the model.
@MainActor
enum WallpaperEngineLocationPanels {
    static func chooseCollection(_ directories: [URL]) -> URL? {
        let alert = NSAlert()
        alert.messageText = "Choose Wallpaper Engine Library"
        alert.informativeText = "Several wallpaper folders were found. Select the folder to open."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let paths = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 640, height: 28))
        paths.addItems(withTitles: directories.map(\.path))
        for item in paths.itemArray { item.toolTip = item.title }
        paths.setAccessibilityLabel("Wallpaper Engine library folder")
        alert.accessoryView = paths
        guard alert.runModal() == .alertFirstButtonReturn,
              directories.indices.contains(paths.indexOfSelectedItem) else { return nil }
        return directories[paths.indexOfSelectedItem]
    }

    static func chooseLocation(_ request: WallpaperEngineLocationPanelRequest) throws -> URL? {
        if let directory = request.directory, !WallpaperEngineLibraryLocations.isAccessibleDirectory(directory) {
            throw WallpaperEngineError.invalid("The wallpaper folder is no longer available: \(directory.path). Reconnect the disk and try again.")
        }
        let panel = NSOpenPanel()
        panel.title = request.importing ? "Import Wallpaper Engine" : "Locate Wallpaper Engine Library"
        panel.prompt = request.importing ? "Import" : "Add Library"
        let instructions = request.importing
            ? "Choose a wallpaper video or HTML file, a project folder, or a Workshop collection. project.json is found automatically."
            : "Choose the 431960 folder or a local Wallpaper Engine project collection. All projects will appear automatically."
        panel.message = request.directory == nil
            ? "No local Wallpaper Engine wallpaper folder was found. Locate it manually. " + instructions
            : instructions
        panel.directoryURL = request.directory
        panel.canChooseDirectories = true
        panel.canChooseFiles = request.importing
        if request.importing { panel.allowedContentTypes = WallpaperEngineViewModel.importContentTypes }
        panel.allowsMultipleSelection = false
        // A disappearing source disk must not silently redirect the panel to its remembered folder.
        let monitor = request.directory.map { WallpaperEngineFolderMonitor(panel: panel, directory: $0) }
        defer { monitor?.stop() }
        let response = panel.runModal()
        if monitor?.unavailable == true || request.directory.map({ !WallpaperEngineLibraryLocations.isAccessibleDirectory($0) }) == true {
            throw WallpaperEngineError.invalid("The wallpaper folder became unavailable. Reconnect the disk and try again.")
        }
        return response == .OK ? panel.url : nil
    }
}

@MainActor
private final class WallpaperEngineFolderMonitor {
    private var task: Task<Void, Never>?
    private(set) var unavailable = false

    init(panel: NSOpenPanel, directory: URL) {
        task = Task { [weak self, weak panel] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                let accessible = await Task.detached(priority: .utility) {
                    WallpaperEngineLibraryLocations.isAccessibleDirectory(directory)
                }.value
                guard !Task.isCancelled, let self, let panel else { return }
                if !accessible { self.unavailable = true; panel.cancel(nil); return }
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
