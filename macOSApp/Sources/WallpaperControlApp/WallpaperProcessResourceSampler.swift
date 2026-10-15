import Darwin
import Foundation

/// Measures a wallpaper's process tree without including the control app or
/// an independent preview. CPU uses the interval between monitoring refreshes.
final class WallpaperProcessResourceSampler: @unchecked Sendable {
    struct Resources: Sendable {
        let pids: [Int]
        let cpuPercent: Double
        let memoryMB: Double
        let virtualMemoryMB: Double
        let threadCount: Int
    }

    private struct ProcessSample {
        let pid: Int
        let parentPID: Int
        let executable: String
        let startTimeMicros: UInt64
        let cpuTime: UInt64
        let memory: UInt64
        let virtualMemory: UInt64
        let threads: Int
    }

    private struct PreviousSample {
        let process: ProcessSample
        let uptime: TimeInterval
    }

    private let lock = NSLock()
    private var previous: [Int: PreviousSample] = [:]
    // proc_taskinfo reports CPU time in Mach ticks, not nanoseconds on ARM.
    private static let cpuSecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    func sample(rootPID: Int, expectedExecutableName: String) -> Resources? {
        lock.lock()
        defer { lock.unlock() }
        guard let root = Self.readProcess(rootPID),
              URL(fileURLWithPath: root.executable).lastPathComponent == expectedExecutableName else {
            previous.removeAll()
            return nil
        }

        var processes = [root]
        var visited: Set<Int> = [rootPID]
        var index = 0
        while index < processes.count {
            let parent = processes[index]
            index += 1
            for pid in Self.children(of: parent.pid) where visited.insert(pid).inserted {
                guard let child = Self.readProcess(pid), child.parentPID == parent.pid,
                      child.startTimeMicros >= parent.startTimeMicros else { continue }
                processes.append(child)
            }
        }
        // A PID can exit and be reused while its descendants are inspected.
        guard let currentRoot = Self.readProcess(rootPID),
              currentRoot.startTimeMicros == root.startTimeMicros,
              currentRoot.executable == root.executable else {
            previous.removeAll()
            return nil
        }

        let uptime = ProcessInfo.processInfo.systemUptime
        let now = Date().timeIntervalSince1970
        var cpuPercent = 0.0
        for process in processes {
            if let old = previous[process.pid],
               old.process.startTimeMicros == process.startTimeMicros,
               process.cpuTime >= old.process.cpuTime, uptime - old.uptime > 0.01 {
                cpuPercent += Double(process.cpuTime - old.process.cpuTime) * Self.cpuSecondsPerTick
                    / (uptime - old.uptime) * 100
            } else {
                let lifetime = now - Double(process.startTimeMicros) / 1_000_000
                if lifetime > 0 {
                    cpuPercent += Double(process.cpuTime) * Self.cpuSecondsPerTick / lifetime * 100
                }
            }
        }
        previous = Dictionary(uniqueKeysWithValues: processes.map {
            ($0.pid, PreviousSample(process: $0, uptime: uptime))
        })
        return Resources(
            pids: processes.map(\.pid).sorted(),
            cpuPercent: max(cpuPercent, 0),
            memoryMB: processes.reduce(0.0) { $0 + Double($1.memory) / 1_048_576 },
            virtualMemoryMB: processes.reduce(0.0) { $0 + Double($1.virtualMemory) / 1_048_576 },
            threadCount: processes.reduce(0) { $0 + $1.threads }
        )
    }

    private static func readProcess(_ pid: Int) -> ProcessSample? {
        guard pid > 0, let processID = pid_t(exactly: pid) else { return nil }
        var bsd = proc_bsdinfo()
        var task = proc_taskinfo()
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &bsd,
                          Int32(MemoryLayout<proc_bsdinfo>.stride)) == MemoryLayout<proc_bsdinfo>.stride,
              bsd.pbi_status != UInt32(SZOMB),
              proc_pidinfo(processID, PROC_PIDTASKINFO, 0, &task,
                           Int32(MemoryLayout<proc_taskinfo>.stride)) == MemoryLayout<proc_taskinfo>.stride,
              proc_pidpath(processID, &path, UInt32(path.count)) > 0 else { return nil }
        return ProcessSample(
            pid: pid, parentPID: Int(bsd.pbi_ppid), executable: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
            startTimeMicros: bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec,
            cpuTime: task.pti_total_user &+ task.pti_total_system,
            memory: task.pti_resident_size, virtualMemory: task.pti_virtual_size,
            threads: Int(task.pti_threadnum)
        )
    }

    private static func children(of pid: Int) -> [Int] {
        var capacity = 32
        while true {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes {
                proc_listchildpids(pid_t(pid), $0.baseAddress, Int32($0.count))
            }
            // Unlike proc_listpids, this convenience API returns a PID count.
            guard count > 0 else { return [] }
            if count < capacity {
                return pids.prefix(Int(count)).filter { $0 > 0 }.map(Int.init)
            }
            capacity *= 2
        }
    }
}
