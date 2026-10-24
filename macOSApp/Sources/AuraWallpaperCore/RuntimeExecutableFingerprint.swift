import CryptoKit
import Foundation

public enum RuntimeExecutableFingerprint {
    /// Captured by the helper at startup, so replacing a same-version app on
    /// disk cannot make an old process look as though it loaded the patch.
    public static func digest(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
