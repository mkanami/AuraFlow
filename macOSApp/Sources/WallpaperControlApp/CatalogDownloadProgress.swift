import Foundation

struct CatalogDownloadProgress: Sendable {
    typealias Handler = @Sendable (CatalogDownloadProgress) -> Void

    enum Phase: Sendable {
        case preparing, downloading, saving, cancelling
    }

    var phase: Phase = .preparing
    var receivedBytes: Int64 = 0
    var totalBytes: Int64?
    let sampledAt = ProcessInfo.processInfo.systemUptime

    var fraction: Double? {
        guard phase == .downloading, let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }

    var label: String {
        switch phase {
        case .preparing: return "Preparing download…"
        case .saving: return "Saving…"
        case .cancelling: return "Cancelling…"
        case .downloading:
            let received = ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .binary)
            if let totalBytes, totalBytes > 0 {
                let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .binary)
                return "\(Int((fraction ?? 0) * 100))% · \(received) / \(total)"
            }
            return receivedBytes > 0 ? "Downloaded \(received)" : "Connecting…"
        }
    }
}

/// Observes the actual transfer task while retaining the caller's session,
/// headers and cookie state. The temporary file is claimed before completion
/// returns to URLSession, which otherwise deletes it immediately.
final class CatalogDownloadObserver: @unchecked Sendable {
    typealias Update = @Sendable (Int64, Int64, URLResponse?) -> Void
    private let update: Update?
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var cancelled = false

    init(update: Update?) { self.update = update }

    func download(request: URLRequest, session: URLSession) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                start(request: request, session: session, continuation: continuation)
            }
        } onCancel: { self.cancel() }
    }

    private func start(request: URLRequest, session: URLSession,
                       continuation: CheckedContinuation<(URL, URLResponse), Error>) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
        let task = session.downloadTask(with: request) { [self] temporaryURL, response, error in
            lock.lock()
            let wasCancelled = cancelled
            observation = nil
            self.task = nil
            lock.unlock()
            do {
                if wasCancelled { throw CancellationError() }
                if let error { throw error }
                guard let temporaryURL, let response else { throw URLError(.badServerResponse) }
                let ownedURL = FileManager.default.temporaryDirectory.appendingPathComponent("AuraFlowTransfer-\(UUID())")
                try FileManager.default.moveItem(at: temporaryURL, to: ownedURL)
                continuation.resume(returning: (ownedURL, response))
            } catch { continuation.resume(throwing: error) }
        }
        self.task = task
        let update = update
        observation = task.observe(\.countOfBytesReceived, options: [.new]) { task, _ in
            update?(task.countOfBytesReceived, task.countOfBytesExpectedToReceive, task.response)
        }
        task.resume()
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

/// Bounds UI updates while also serializing parallel chunk progress.
final class CatalogDownloadProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: CatalogDownloadProgress.Handler?
    private var lastUpdate: TimeInterval = 0
    private var parts: [Int64: Int64] = [:]

    init(handler: CatalogDownloadProgress.Handler?) { self.handler = handler }

    func report(received: Int64, total: Int64?, force: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        emit(received: received, total: total, force: force)
    }

    func reportPart(key: Int64, received: Int64, total: Int64, force: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        parts[key] = max(0, received)
        emit(received: parts.values.reduce(0, +), total: total, force: force)
    }

    private func emit(received: Int64, total: Int64?, force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastUpdate >= 0.1 else { return }
        lastUpdate = now
        handler?(.init(phase: .downloading, receivedBytes: max(received, 0),
                       totalBytes: total.flatMap { $0 > 0 ? $0 : nil }))
    }
}
