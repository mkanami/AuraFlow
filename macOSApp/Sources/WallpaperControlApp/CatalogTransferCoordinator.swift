import Foundation

struct CatalogForegroundDownloadLease: Sendable, Equatable {
    fileprivate let token: UUID
}

actor CatalogTransferCoordinator {
    enum Mode: Sendable, Equatable {
        case idle
        case selectedPreview(UUID)
        case foregroundDownload(UUID)
    }

    private(set) var mode: Mode = .idle
    private var foregroundToken: UUID?

    func beginSelectedPreview() -> UUID? {
        guard foregroundToken == nil else { return nil }
        let token = UUID()
        mode = .selectedPreview(token)
        return token
    }

    func endSelectedPreview(_ token: UUID) {
        guard mode == .selectedPreview(token) else { return }
        mode = .idle
    }

    func beginForegroundDownload() -> CatalogForegroundDownloadLease {
        let token = UUID()
        foregroundToken = token
        mode = .foregroundDownload(token)
        return CatalogForegroundDownloadLease(token: token)
    }

    func endForegroundDownload(_ lease: CatalogForegroundDownloadLease) {
        guard foregroundToken == lease.token else { return }
        foregroundToken = nil
        mode = .idle
    }

    func permitsBackgroundMedia() -> Bool {
        foregroundToken == nil
    }
}
