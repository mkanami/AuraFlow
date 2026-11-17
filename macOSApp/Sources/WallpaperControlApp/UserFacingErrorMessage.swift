import Foundation
import Darwin

/// Keep system error codes for diagnosis while presenting the cause and a
/// useful next step instead of temporary paths and runtime implementation names.
enum UserFacingErrorMessage {
    static func describe(_ error: Error) -> String {
        knownProblem(error) ?? error.localizedDescription
    }

    static func knownProblem(_ error: Error) -> String? {
        var pending: [Error] = [error]
        var errors: [NSError] = []
        while let next = pending.popLast(), errors.count < 16 {
            if case let NativeWallpaperControllerError.startRollbackFailed(cause, _) = next {
                pending.append(cause)
            }
            let system = next as NSError
            errors.append(system)
            if let cause = system.userInfo[NSUnderlyingErrorKey] as? Error { pending.append(cause) }
        }

        // A generic outer write error can wrap the actual storage failure.
        if errors.contains(where: {
            ($0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteOutOfSpaceError)
                || ($0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOSPC))
        }) {
            return "Not enough disk space. Free up space on your Mac, then try again."
        }
        for error in errors {
            switch (error.domain, error.code) {
            case (NSCocoaErrorDomain, NSFileReadNoPermissionError),
                 (NSCocoaErrorDomain, NSFileWriteNoPermissionError),
                 (NSPOSIXErrorDomain, Int(EACCES)), (NSPOSIXErrorDomain, Int(EPERM)):
                return "AuraFlow cannot access a required file. Check its permissions, then try again."
            case (NSCocoaErrorDomain, NSFileNoSuchFileError),
                 (NSCocoaErrorDomain, NSFileReadNoSuchFileError), (NSPOSIXErrorDomain, Int(ENOENT)):
                return "File not found. It may have been moved or deleted. Choose the file again."
            case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet):
                return "No internet connection. Check your connection, then try again."
            case (NSURLErrorDomain, NSURLErrorTimedOut):
                return "The server took too long to respond. Try again in a moment."
            case (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
                return "The connection was interrupted. Check your internet connection, then try again."
            case (NSURLErrorDomain, NSURLErrorCannotFindHost),
                 (NSURLErrorDomain, NSURLErrorCannotConnectToHost):
                return "The server is unavailable. Check your connection or try again later."
            default: continue
            }
        }
        return nil
    }
}
