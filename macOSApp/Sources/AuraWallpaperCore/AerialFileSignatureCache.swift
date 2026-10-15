import Darwin
import Foundation

/// Only periodic health verification may reuse a hash. Installation, rearming,
/// source changes and explicit repairs retain full reads by default.
public enum AerialFileSignatureValidation {
    @TaskLocal public static var allowsCachedRead = false
}

final class AerialFileSignatureCache {
    private struct Metadata: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init?(url: URL) {
            var info = stat()
            guard url.path.withCString({ stat($0, &info) }) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }
    private struct Entry {
        let metadata: Metadata
        let signature: String
        let createdAt: TimeInterval
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let clock: () -> TimeInterval

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    func signature(at url: URL, allowCached: Bool, read: () throws -> String) rethrows -> String {
        let path = url.standardizedFileURL.path
        let before = Metadata(url: url)
        let now = clock()
        lock.lock()
        let entry = entries[path]
        lock.unlock()
        if allowCached, let before, let entry, before == entry.metadata,
           now >= entry.createdAt, now - entry.createdAt < 60 {
            return entry.signature
        }
        let signature: String
        do {
            signature = try read()
        } catch {
            lock.lock()
            entries[path] = nil
            lock.unlock()
            throw error
        }
        let after = Metadata(url: url)
        lock.lock()
        defer { lock.unlock() }
        if let before, before == after {
            if entries.count >= 16 { entries.removeAll(keepingCapacity: true) }
            entries[path] = Entry(metadata: before, signature: signature, createdAt: now)
        } else {
            entries[path] = nil
        }
        return signature
    }
}
