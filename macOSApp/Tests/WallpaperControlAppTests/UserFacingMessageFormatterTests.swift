import Testing
@testable import WallpaperControlApp

@Test func userFacingMessagesDoNotEndWithAFullStop() {
    #expect(
        UserFacingMessageFormatter.format("Wallpaper started.")
            == "Wallpaper started"
    )
    #expect(
        UserFacingMessageFormatter.format(
            "Wallpaper removed. The original wallpaper was restored."
        ) == "Wallpaper removed. The original wallpaper was restored"
    )
    #expect(
        UserFacingMessageFormatter.format("Failed to start.   ")
            == "Failed to start   "
    )
}

@Test func userFacingMessagesKeepOtherTerminalPunctuation() {
    #expect(
        UserFacingMessageFormatter.format("Preparing optimization...")
            == "Preparing optimization..."
    )
    #expect(
        UserFacingMessageFormatter.format("Preparing optimization…")
            == "Preparing optimization…"
    )
    #expect(
        UserFacingMessageFormatter.format("Try again!")
            == "Try again!"
    )
}
