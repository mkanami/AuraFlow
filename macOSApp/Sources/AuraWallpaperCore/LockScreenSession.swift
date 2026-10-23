import CoreGraphics
import Foundation

/// An unavailable WindowServer session is unknown, never an unlock signal.
public enum LockScreenSession {
    public static func currentIsLocked() -> Bool? {
        isLocked(in: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    public static func isLocked(in session: [String: Any]?) -> Bool? {
        guard let session else { return nil }
        if let locked = session["CGSSessionScreenIsLocked"] as? NSNumber {
            return locked.boolValue
        }
        let onConsole = (session["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue
        let loginDone = (session["kCGSessionLoginDoneKey"] as? NSNumber)?.boolValue
        return onConsole == true && loginDone == true ? false : nil
    }
}
