import Testing
@testable import WallpaperControlApp

@Test(arguments: [false, true], [false, true])
func terminalWallpaperAppliedBadgeDoesNotDisablePreview(installed: Bool, applied: Bool) {
    let card = TerminalWallpaperCardPresentation(
        installed: installed, selectedForPreview: false, applied: applied, busy: false
    )
    #expect(!card.actionDisabled)
    #expect(card.applied == applied)
    #expect(card.actionTitle == (installed ? "Show in preview" : "Install & show in preview"))
}

@Test func terminalWallpaperSelectedMissingProgramStillOffersInstallation() {
    let card = TerminalWallpaperCardPresentation(
        installed: false, selectedForPreview: true, applied: false, busy: false
    )
    #expect(!card.actionDisabled)
    #expect(card.actionTitle == "Install & show in preview")
    #expect(card.availabilityTitle == "Installation required")
}

@Test func terminalWallpaperSelectedInstalledCardAvoidsDuplicatePreview() {
    let card = TerminalWallpaperCardPresentation(
        installed: true, selectedForPreview: true, applied: false, busy: false
    )
    #expect(card.actionDisabled)
    #expect(card.actionTitle == "In preview")
    #expect(card.availabilityTitle == nil)
    #expect(!card.applied)
}

@Test(arguments: [false, true], [false, true])
func terminalWallpaperBusyCardsCannotSubmitAgain(installed: Bool, selected: Bool) {
    let card = TerminalWallpaperCardPresentation(
        installed: installed, selectedForPreview: selected, applied: false, busy: true
    )
    #expect(card.actionDisabled)
}
