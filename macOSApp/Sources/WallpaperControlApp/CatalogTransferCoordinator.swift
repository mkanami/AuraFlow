import Foundation

struct CatalogForegroundDownloadLease: Sendable, Equatable {
    fileprivate let token: UUID
}

actor CatalogTransferCoordinator {
    private var foregroundToken: UUID?

    func beginForegroundDownload() -> CatalogForegroundDownloadLease {
        let token = UUID()
        foregroundToken = token
        return CatalogForegroundDownloadLease(token: token)
    }

    func endForegroundDownload(_ lease: CatalogForegroundDownloadLease) {
        guard foregroundToken == lease.token else { return }
        foregroundToken = nil
    }

    func permitsBackgroundMedia() -> Bool {
        foregroundToken == nil
    }
}
