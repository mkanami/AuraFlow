import AuraTerminalWallpaperCore
import AuraWallpaperCore
import Foundation
import Testing

@Test func terminalScaleDefaultsToFillForNewAndLegacySettings() throws {
    #expect(TerminalRenderConfiguration().scaleMode == .fill)
    #expect(TerminalWallpaperConfig.defaultConfig.render.scaleMode == .fill)
    let legacy = try JSONDecoder().decode(TerminalRenderConfiguration.self, from: Data("{}".utf8))
    #expect(legacy.scaleMode == .fill)
}

@Test(arguments: TerminalScaleMode.allCases)
func terminalScaleDefaultsPreserveSavedChoice(mode: TerminalScaleMode) throws {
    let saved = TerminalRenderConfiguration(scaleMode: mode)
    let restored = try JSONDecoder().decode(TerminalRenderConfiguration.self, from: JSONEncoder().encode(saved))
    #expect(restored.scaleMode == mode)
}

@Test func wallpaperDefaultsEnableLockScreenAndPreserveExplicitOff() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WallpaperRuntimeStore(appSupportURL: root)
    #expect(ControlConfig.defaultConfig.show_on_lock_screen == true)
    #expect(ControlConfig.defaultConfig.scale_mode == "fill")
    #expect(store.loadConfig().show_on_lock_screen == true)
    let legacy = try JSONDecoder().decode(ControlConfig.self,
        from: Data(#"{"video_path":"","playback_speed":1}"#.utf8))
    #expect(store.normalized(legacy).show_on_lock_screen == true)
    var disabled = legacy
    disabled.show_on_lock_screen = false
    try store.saveConfig(disabled)
    #expect(store.loadConfig().show_on_lock_screen == false)
}
