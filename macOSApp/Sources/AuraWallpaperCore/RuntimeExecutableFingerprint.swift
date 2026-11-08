import CryptoKit
import Foundation

public enum RuntimeExecutableFingerprint {
    private static let verificationCache = AerialFileSignatureCache()

    /// Captured by the helper at startup, so replacing a same-version app on
    /// disk cannot make an old process look as though it loaded the patch.
    public static func digest(at url: URL, allowCachedRead: Bool = false) -> String? {
        // Periodic verification can reuse a bounded, metadata-validated hash.
        // Startup captures still read the executable in full by default.
        try? verificationCache.signature(at: url, allowCached: allowCachedRead) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}
