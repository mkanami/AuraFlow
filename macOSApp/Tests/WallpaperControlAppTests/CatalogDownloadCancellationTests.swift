import Foundation
import Testing
@testable import WallpaperControlApp

@Test func catalogDownloadCancellationDoesNotTryNextSource() async throws {
    let recorder = DownloadAttemptRecorder()
    let catalogDirectory = temporaryCatalogDirectory()
    defer { try? FileManager.default.removeItem(at: catalogDirectory) }

    let service = CatalogDownloadService(
        provider: CancellationTestCatalogProvider(),
        catalogDirectoryURL: catalogDirectory,
        fileDownloader: { _, _ in
            recorder.recordAttempt()
            throw CancellationError()
        }
    )

    do {
        _ = try await service.download(cancellationTestWallpaper)
        Issue.record("Expected catalog download cancellation.")
    } catch is CancellationError {
        // Cancellation must stop the source loop immediately.
    } catch {
        Issue.record("Expected CancellationError, got \(error).")
    }

    #expect(recorder.attemptCount == 1)
}

@Test func catalogDownloadChecksCancellationBeforeFirstAttempt() async throws {
    let recorder = DownloadAttemptRecorder()
    let catalogDirectory = temporaryCatalogDirectory()
    defer { try? FileManager.default.removeItem(at: catalogDirectory) }

    let service = CatalogDownloadService(
        provider: CancellationTestCatalogProvider(),
        catalogDirectoryURL: catalogDirectory,
        fileDownloader: { _, _ in
            recorder.recordAttempt()
            throw CancellationError()
        }
    )

    let task = Task {
        try await service.download(cancellationTestWallpaper)
    }
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("Expected catalog download cancellation.")
    } catch is CancellationError {
        // The pre-cancelled task must not enter any download or fallback path.
    } catch {
        Issue.record("Expected CancellationError, got \(error).")
    }

    #expect(recorder.attemptCount == 0)
}

private let cancellationTestWallpaper = CatalogWallpaper(
    id: "cancellation-test",
    title: "Cancellation Test",
    category: "Scenic",
    attribution: "Test",
    previewImageURL: nil,
    sourcePageURL: nil,
    sources: [
        CatalogVideoSource(
            url: URL(string: "https://cdn-one.invalid/wallpaper.mp4")!,
            width: 1920,
            height: 1080
        ),
        CatalogVideoSource(
            url: URL(string: "https://cdn-two.invalid/wallpaper.mp4")!,
            width: 1920,
            height: 1080
        )
    ]
)

private struct CancellationTestCatalogProvider: WallpaperCatalogProviding {
    func loadCachedCatalog() async -> [CatalogWallpaper]? { nil }

    func fetchCatalog() async throws -> [CatalogWallpaper] {
        []
    }

    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL {
        throw CancellationError()
    }
}

private final class DownloadAttemptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func recordAttempt() {
        lock.lock()
        attempts += 1
        lock.unlock()
    }
}

private func temporaryCatalogDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowCatalogCancellation-\(UUID().uuidString)", isDirectory: true)
}
