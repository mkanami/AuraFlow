import Foundation
import Darwin

/// A catalog soundtrack lives beside its video, so deleting the catalog's
/// temporary cache cannot break an already downloaded wallpaper.
public enum WallpaperAudioAttachment {
    public static func companionURL(for video: URL) -> URL {
        video.appendingPathExtension("auraflow-audio.mp3")
    }

    public static func source(for video: URL) -> URL {
        guard video.isFileURL else { return video }
        let companion = companionURL(for: video)
        let attributes = try? FileManager.default.attributesOfItem(atPath: companion.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0 > 0 ? companion : video
    }

    public static func install(_ soundtrack: URL, for video: URL) throws {
        let destination = companionURL(for: video)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".soundtrack-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do { try FileManager.default.linkItem(at: soundtrack, to: temporary) }
        catch { try FileManager.default.copyItem(at: soundtrack, to: temporary) }
        // rename is atomic within this directory and handles an existing hard
        // link to the same inode. FileManager's replacement rejects that case.
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    public static func remove(for video: URL) {
        try? FileManager.default.removeItem(at: companionURL(for: video))
    }
}
