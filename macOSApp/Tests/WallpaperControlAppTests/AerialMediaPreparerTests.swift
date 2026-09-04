import Foundation
import Testing
@testable import AuraWallpaperCore

private struct AerialMediaPreparerFixture {
    let root: URL
    let sourceURL: URL
    let cacheURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AuraFlowAerialMediaPreparer-\(UUID().uuidString)",
                isDirectory: true
            )
        sourceURL = root.appendingPathComponent("source.data")
        cacheURL = root.appendingPathComponent("prepared", isDirectory: true)

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("not an image or movie".utf8).write(to: sourceURL)
    }

    func makeExecutable(named name: String, body: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Test func aerialMediaPreparerPropagatesConversionFailureWithoutBlocking() async throws {
    let fixture = try AerialMediaPreparerFixture()
    defer { fixture.cleanup() }
    let converter = try fixture.makeExecutable(
        named: "failing-converter.sh",
        body: "#!/bin/sh\necho 'fixture conversion failed' >&2\nexit 7\n"
    )
    let preparer = AerialMediaPreparer(
        fileManager: .default,
        usesCanonicalWallpaperStore: true,
        preparedCacheDirectoryURL: fixture.cacheURL,
        conversionExecutableURL: converter
    )

    do {
        _ = try await preparer.prepare(from: fixture.sourceURL)
        Issue.record("Expected conversion to fail")
    } catch {
        #expect(error.localizedDescription.contains("fixture conversion failed"))
    }
}

@Test func aerialMediaPreparerCancellationTerminatesConversionAndCleansOutput() async throws {
    let fixture = try AerialMediaPreparerFixture()
    defer { fixture.cleanup() }
    let converter = try fixture.makeExecutable(
        named: "slow-converter.sh",
        body: "#!/bin/sh\nexec sleep 30\n"
    )
    let preparer = AerialMediaPreparer(
        fileManager: .default,
        usesCanonicalWallpaperStore: true,
        preparedCacheDirectoryURL: fixture.cacheURL,
        conversionExecutableURL: converter
    )

    let task = Task {
        try await preparer.prepare(from: fixture.sourceURL)
    }
    try await Task.sleep(nanoseconds: 100_000_000)

    let cancellationStart = Date()
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("Expected conversion cancellation")
    } catch is CancellationError {
        #expect(Date().timeIntervalSince(cancellationStart) < 5.0)
    } catch {
        Issue.record("Expected CancellationError, got \(error)")
    }

    #expect(
        FileManager.default.fileExists(
            atPath: fixture.cacheURL.path
        )
    )
    let temporaryOutputs = try FileManager.default.contentsOfDirectory(
        at: fixture.cacheURL,
        includingPropertiesForKeys: nil
    )
    #expect(temporaryOutputs.isEmpty)
}
