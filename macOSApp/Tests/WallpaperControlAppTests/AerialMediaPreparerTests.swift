import AVFoundation
import CoreVideo
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

private func writeHEVCTestMovie(to url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 32,
            AVVideoHeightKey: 32,
        ]
    )
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: 32,
            kCVPixelBufferHeightKey as String: 32,
        ]
    )
    guard writer.canAdd(input) else {
        throw CocoaError(.fileWriteUnknown)
    }
    writer.add(input)
    guard writer.startWriting() else {
        throw writer.error ?? CocoaError(.fileWriteUnknown)
    }
    writer.startSession(atSourceTime: .zero)

    for frame in 0..<60 {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            32,
            32,
            kCVPixelFormatType_32ARGB,
            nil,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else {
            writer.cancelWriting()
            throw CocoaError(.fileWriteUnknown)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            baseAddress.initializeMemory(
                as: UInt8.self,
                repeating: UInt8(frame % 255),
                count: 32 * 32 * 4
            )
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        guard adaptor.append(
            pixelBuffer,
            withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)
        ) else {
            writer.cancelWriting()
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw writer.error ?? CocoaError(.fileWriteUnknown)
    }
}

@Test func aerialMediaPreparerPhysicallyRetimesEveryVideoSample() async throws {
    let fixture = try AerialMediaPreparerFixture()
    defer { fixture.cleanup() }
    let movieURL = fixture.root.appendingPathComponent("source.mov")
    try await writeHEVCTestMovie(to: movieURL)
    let preparer = AerialMediaPreparer(
        fileManager: .default,
        usesCanonicalWallpaperStore: true,
        preparedCacheDirectoryURL: fixture.cacheURL
    )

    let sourceDuration = try await AVURLAsset(url: movieURL).load(.duration)
    let fastURL = try await preparer.prepare(
        from: movieURL,
        playbackSpeed: 2.0
    )
    let fastAsset = AVURLAsset(url: fastURL)
    let fastDuration = try await fastAsset.load(.duration)
    let fastTrack = try #require(
        try await fastAsset.load(.tracks).first { $0.mediaType == .video }
    )
    let reader = try AVAssetReader(asset: fastAsset)
    let output = AVAssetReaderTrackOutput(track: fastTrack, outputSettings: nil)
    reader.add(output)
    #expect(reader.startReading())
    var presentationTimes: [CMTime] = []
    while let sample = output.copyNextSampleBuffer() {
        presentationTimes.append(
            CMSampleBufferGetPresentationTimeStamp(sample)
        )
    }

    #expect(abs(fastDuration.seconds - sourceDuration.seconds / 2.0) < 0.08)
    let uniquePresentationSeconds = Array(
        Set(presentationTimes.map { $0.seconds })
    ).sorted()
    #expect(uniquePresentationSeconds.count >= 58)
    let finalPresentationTime = uniquePresentationSeconds.last ?? 0
    #expect(finalPresentationTime > 0.8)
    #expect(finalPresentationTime < 1.3)
    #expect(fastURL.lastPathComponent.contains("prepared-v3-"))
}

@Test func aerialMediaPreparerBakesFitAndStretchIntoDisplayCanvas() async throws {
    let fixture = try AerialMediaPreparerFixture()
    defer { fixture.cleanup() }
    let movieURL = fixture.root.appendingPathComponent("source.mov")
    try await writeHEVCTestMovie(to: movieURL)
    let preparer = AerialMediaPreparer(
        fileManager: .default,
        usesCanonicalWallpaperStore: true,
        preparedCacheDirectoryURL: fixture.cacheURL
    )
    let displaySize = CGSize(width: 1_600, height: 1_000)

    let fitURL = try await preparer.prepare(
        from: movieURL,
        playbackSpeed: 1.0,
        scaleMode: .fit,
        targetDisplaySize: displaySize
    )
    let stretchURL = try await preparer.prepare(
        from: movieURL,
        playbackSpeed: 1.0,
        scaleMode: .stretch,
        targetDisplaySize: displaySize
    )

    let fitTrack = try #require(
        try await AVURLAsset(url: fitURL).load(.tracks).first {
            $0.mediaType == .video
        }
    )
    let naturalSize = try await fitTrack.load(.naturalSize)
    let transform = try await fitTrack.load(.preferredTransform)
    let displayRect = CGRect(origin: .zero, size: naturalSize)
        .applying(transform)
    let aspect = abs(displayRect.width / displayRect.height)

    #expect(abs(aspect - 1.6) < 0.05)
    #expect(fitURL.lastPathComponent.contains("-fit-"))
    #expect(stretchURL.lastPathComponent.contains("-stretch-"))
    #expect(fitURL != stretchURL)
    #expect(try await preparer.isCompatible(at: fitURL))
    #expect(try await preparer.isCompatible(at: stretchURL))
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
