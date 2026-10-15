import AuraTerminalWallpaperCore
import AuraWallpaperCore
import Foundation

struct WallpaperMonitoringSnapshot: Sendable {
    let metrics: DaemonMetrics
    var terminalProgram: String?
    var terminalHealth: TerminalWallpaperHealth?

    var isTerminal: Bool { terminalProgram != nil }
}

final class TerminalWallpaperMonitoring: @unchecked Sendable {
    private let store: TerminalWallpaperRuntimeStore
    private let sampler = WallpaperProcessResourceSampler()
    private let expectedExecutableName: String

    init(store: TerminalWallpaperRuntimeStore, expectedExecutableName: String = "AuraTerminalWallpaperAgent") {
        self.store = store
        self.expectedExecutableName = expectedExecutableName
    }

    func snapshot() -> WallpaperMonitoringSnapshot? {
        let status = store.status()
        guard let pid = status.pid,
              let resources = sampler.sample(rootPID: pid, expectedExecutableName: expectedExecutableName) else { return nil }
        let now = Date().timeIntervalSince1970
        let health = status.health
        let lag = health.map { max(now - $0.updatedAt, 0) }
        let fresh = health.map { $0.fresh && now >= $0.updatedAt && (lag ?? 0) < 6 } ?? false
        let reason = health?.lastError ?? (fresh ? "ok" : "stale-health")
        return WallpaperMonitoringSnapshot(
            metrics: DaemonMetrics(
                updated_at: now, running: status.running, paused: status.paused,
                pid: pid, daemon_pids: resources.pids, process_count: resources.pids.count,
                cpu_percent: resources.cpuPercent, memory_mb: resources.memoryMB,
                virtual_memory_mb: resources.virtualMemoryMB, thread_count: resources.threadCount,
                health: DaemonHealth(
                    available: true, fresh: fresh, suspicious: !fresh || health?.lastError != nil,
                    reason: reason, updated_at: health?.updatedAt, lag_seconds: lag,
                    screens: fresh ? health?.screens : nil, windows: fresh ? health?.screens : nil
                )
            ),
            terminalProgram: URL(fileURLWithPath: status.config.command.executable).lastPathComponent,
            terminalHealth: fresh ? health : nil
        )
    }
}
