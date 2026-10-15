import Foundation
import Network
import Testing
@testable import WallpaperControlApp

@Test(arguments: [false, true])
func catalogDownloadReportsBytesBeforeCompletion(unknownSize: Bool) async throws {
    let server = try ProgressHTTPServer()
    let baseURL = try await server.start()
    defer { server.stop() }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let recorder = DownloadProgressRecorder()
    let request = URLRequest(url: baseURL.appendingPathComponent("\(unknownSize ? "unknown" : "known").mp4"))
    let result = try await CatalogFileDownloader.download(request: request, session: session, progress: { recorder.append($0) })
    defer { try? FileManager.default.removeItem(at: result.temporaryURL) }
    #expect(try Data(contentsOf: result.temporaryURL).count == ProgressHTTPServer.totalBytes)
    let intermediate = recorder.values.filter { $0.receivedBytes > 0 && $0.receivedBytes < ProgressHTTPServer.totalBytes }
    #expect(!intermediate.isEmpty)
    if unknownSize {
        #expect(intermediate.allSatisfy { $0.totalBytes == nil && $0.fraction == nil })
    } else {
        #expect(intermediate.allSatisfy { $0.totalBytes == Int64(ProgressHTTPServer.totalBytes) })
        #expect(intermediate.contains { ($0.fraction ?? 0) > 0 && ($0.fraction ?? 1) < 1 })
        #expect(recorder.values.last?.fraction == 1)
    }
}

@Test @MainActor func catalogDownloadCancelClearsProgressAndAllowsAnotherDownload() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraDownloadUI-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try ProgressHTTPServer()
    let baseURL = try await server.start()
    defer { server.stop() }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let provider = DownloadProgressProvider()
    let service = CatalogDownloadService(provider: provider, catalogDirectoryURL: root.appendingPathComponent("Catalog"),
                                         standardSession: session, browserSession: session)
    let model = AppViewModel(controller: MockNativeWallpaperController(), catalogProvider: provider,
                             appSupportDirectoryURL: root, catalogDownloadService: service)
    let wallpaper = progressWallpaper(url: baseURL.appendingPathComponent("known.mp4"))
    for _ in 0..<2 {
        model.applyCatalogWallpaper(wallpaper)
        for _ in 0..<200 where (model.catalogViewModel.downloadProgress?.receivedBytes ?? 0) == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect((model.catalogViewModel.downloadProgress?.receivedBytes ?? 0) > 0)
        #expect(!model.canDownloadCatalogWallpaper)
        model.cancelCatalogDownload()
        #expect(model.catalogViewModel.isDownloadCancelling)
        for _ in 0..<200 where model.catalogDownloadID != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(model.catalogDownloadID == nil && model.catalogViewModel.downloadProgress == nil)
        #expect(!model.catalogViewModel.isDownloadCancelling && model.canDownloadCatalogWallpaper)
        #expect(model.alertMessage == nil)
        #expect(model.downloadedCatalogWallpapers.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Catalog/Downloaded Wallpapers").path)
        #expect(files.isEmpty)
    }
}

private func progressWallpaper(url: URL) -> CatalogWallpaper {
    .init(id: "progress-wallpaper", title: "Progress Wallpaper", category: "Scenic", attribution: "Test",
          previewImageURL: nil, sourcePageURL: nil,
          sources: [.init(url: url, width: 1920, height: 1080)])
}

private struct DownloadProgressProvider: WallpaperCatalogProviding, WallpaperCatalogMediaResolving {
    func loadCachedCatalog() async -> [CatalogWallpaper]? { [] }
    func fetchCatalog() async throws -> [CatalogWallpaper] { [] }
    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL { wallpaper.sources[0].url }
    func resolveMedia(for wallpaper: CatalogWallpaper) async throws -> CatalogResolvedMedia {
        .init(previewSources: [], originalSources: wallpaper.sources, provider: "Test", validUntil: Date().addingTimeInterval(60))
    }
}

private final class DownloadProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [CatalogDownloadProgress] = []
    func append(_ progress: CatalogDownloadProgress) { lock.lock(); defer { lock.unlock() }; snapshots.append(progress) }
    var values: [CatalogDownloadProgress] { lock.lock(); defer { lock.unlock() }; return snapshots }
}

/// A paced HTTP body verifies progress while the actual transfer is in flight.
private final class ProgressHTTPServer: @unchecked Sendable {
    static let totalBytes = 512 * 1024
    private let queue = DispatchQueue(label: "AuraDownloadProgressTest")
    private let listener: NWListener
    private var connections: [NWConnection] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { [self] connection in
            connections.append(connection)
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, _, error in
                guard error == nil, let data else { connection.cancel(); return }
                let unknown = String(decoding: data, as: UTF8.self).contains("/unknown.mp4")
                let length = unknown ? "" : "Content-Length: \(Self.totalBytes)\r\n"
                let header = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\n\(length)Connection: close\r\n\r\n"
                connection.send(content: Data(header.utf8), completion: .contentProcessed { [self] error in
                    guard error == nil else { connection.cancel(); return }
                    sendChunk(0, connection: connection)
                })
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")!)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func sendChunk(_ index: Int, connection: NWConnection) {
        queue.asyncAfter(deadline: .now() + 0.125) { [self] in
            connection.send(content: Data(repeating: UInt8(index), count: Self.totalBytes / 8), completion: .contentProcessed { [self] error in
                guard error == nil else { connection.cancel(); return }
                if index == 7 { connection.cancel() }
                else { sendChunk(index + 1, connection: connection) }
            })
        }
    }

    func stop() {
        listener.newConnectionHandler = nil
        listener.cancel()
        queue.async { [self] in connections.forEach { $0.cancel() }; connections = [] }
    }
}
