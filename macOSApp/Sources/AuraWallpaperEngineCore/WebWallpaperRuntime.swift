import AppKit
import Darwin
import Foundation

public struct WebWallpaperConfiguration: Codable, Equatable, Sendable {
    public var project: WallpaperEngineProject
    public var values: [String: ProjectValue]
    public var fps: Int = 30
    public var pauseOnFullscreen: Bool = true
    public var generation: String = UUID().uuidString
    public init(project: WallpaperEngineProject, values: [String: ProjectValue]) {
        self.project = project; self.values = values
    }
}

public struct WebWallpaperStatus: Codable, Equatable, Sendable {
    public var pid: Int32
    public var generation: String
    public var projectID: String
    public var frames: [String: String]
    public var expectedDisplays: [String] = []
    public var paused: Bool
    public var error: String?
    public init(pid: Int32, generation: String, projectID: String, frames: [String: String] = [:], paused: Bool = false, error: String? = nil) {
        self.pid = pid; self.generation = generation; self.projectID = projectID
        self.frames = frames; self.paused = paused; self.error = error
    }
    public var ready: Bool { error == nil && !expectedDisplays.isEmpty && expectedDisplays.allSatisfy { id in
        frames[id].map { FileManager.default.fileExists(atPath: $0) } == true
    } }
}

public enum WebWallpaperRuntime {
    public static let changed = Notification.Name("com.andrijvergeles.auraflow.web-runtime-changed")
    public static var root: URL { WallpaperEngineLibrary.defaultRoot.appendingPathComponent("runtime") }
    public static func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    public static func write<T: Encodable>(_ value: T, to name: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url(name), options: .atomic)
    }
    public static func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    public static func alive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }
    public static func isAgent(_ pid: Int32) -> Bool {
        guard alive(pid) else { return false }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).lastPathComponent == "AuraWebWallpaperAgent"
    }
    public static var status: WebWallpaperStatus? {
        guard let state = read(WebWallpaperStatus.self, from: "status.json"), isAgent(state.pid) else { return nil }
        return state
    }
    public static var agentPID: Int32? {
        guard let text = try? String(contentsOf: url("agent.pid")), let pid = Int32(text), isAgent(pid) else { return nil }
        return pid
    }
    public static var active: Bool { agentPID != nil || status != nil || FileManager.default.fileExists(atPath: url("route-active").path) }
}

public struct WebWallpaperPausePolicy {
    public static func shouldUnload(visible: Bool, locked: Bool, fullscreen: Bool, pauseOnFullscreen: Bool) -> Bool {
        !visible || locked || (pauseOnFullscreen && fullscreen)
    }
}

public struct WebWallpaperGenerationGate {
    public private(set) var generation = UUID().uuidString
    public init() {}
    public mutating func replace() { generation = UUID().uuidString }
    public func accepts(_ token: String) -> Bool { token == generation }
}
