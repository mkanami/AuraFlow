import CoreGraphics
import Foundation
import Darwin

/// An unavailable WindowServer session is unknown, never an unlock signal.
public enum LockScreenSession {
    private static let bootIdentifier: String? = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }()

    public static func currentIdentifier() -> String? {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard let bootIdentifier,
              let auditID = session?["kCGSSessionAuditIDKey"] as? NSNumber else { return nil }
        return bootIdentifier + ":" + auditID.stringValue
    }

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
