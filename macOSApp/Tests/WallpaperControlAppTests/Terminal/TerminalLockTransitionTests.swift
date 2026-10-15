import Testing
@testable import AuraTerminalWallpaperAgent

@Test func terminalLockDoesNotStartSaverOnLaunchOrUnknownSession() {
    var state = TerminalLockTransition()
    #expect(state.update(nil) == nil)
    #expect(state.update(false) == nil)
    #expect(!state.locked)
}

@Test func terminalLockDeduplicatesAndKeepsStateAcrossUnavailableSession() {
    var state = TerminalLockTransition()
    #expect(state.update(true) == true)
    #expect(state.update(true) == nil)
    #expect(state.update(nil) == nil)
    #expect(state.locked)
    #expect(state.update(false) == false)
    #expect(state.update(false) == nil)
    #expect(state.update(true) == true)
}
