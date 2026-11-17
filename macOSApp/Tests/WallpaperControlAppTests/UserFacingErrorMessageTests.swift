import Foundation
import Darwin
import Testing
@testable import WallpaperControlApp

@Test(arguments: [
    NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
        userInfo: [NSLocalizedDescriptionKey: "A localized system message about .config.json.tmp"]),
    NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
    NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
])
func userFacingStorageFailureExplainsTheCauseWithoutTemporaryPaths(error: NSError) {
    let message = UserFacingErrorMessage.describe(error)
    #expect(message == "Not enough disk space. Free up space on your Mac, then try again.")
    #expect(!message.contains("config.json") && !message.contains("runtime"))
}

@Test func userFacingStorageFailureSurvivesAnIncompleteStartRollback() {
    let cause = CocoaError(.fileWriteOutOfSpace)
    let wrapped = NativeWallpaperControllerError.startRollbackFailed(cause: cause,
        failures: ["config: Could not save .config.json.tmp"])
    #expect(UserFacingErrorMessage.describe(wrapped) == UserFacingErrorMessage.describe(cause))
    #expect(wrapped.localizedDescription.contains("rollback failed"), "Diagnostics retain the failed recovery details")
}

@Test(arguments: [
    (NSCocoaErrorDomain, NSFileWriteNoPermissionError, "cannot access"),
    (NSCocoaErrorDomain, NSFileReadNoSuchFileError, "File not found"),
    (NSURLErrorDomain, NSURLErrorNotConnectedToInternet, "No internet connection"),
    (NSURLErrorDomain, NSURLErrorTimedOut, "server took too long"),
    (NSURLErrorDomain, NSURLErrorNetworkConnectionLost, "connection was interrupted"),
    (NSURLErrorDomain, NSURLErrorCannotConnectToHost, "server is unavailable")
])
func userFacingErrorsDistinguishFileAndNetworkProblems(domain: String, code: Int, expected: String) {
    #expect(UserFacingErrorMessage.describe(NSError(domain: domain, code: code)).contains(expected))
}

@Test func userFacingUnknownErrorKeepsItsSpecificExplanation() {
    let error = NativeWallpaperControllerError.unavailable("This wallpaper has no audio track.")
    #expect(UserFacingErrorMessage.describe(error) == "This wallpaper has no audio track.")
    #expect(UserFacingErrorMessage.knownProblem(error) == nil)
}
