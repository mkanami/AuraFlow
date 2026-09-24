import Foundation

public struct TerminalRGBA: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = TerminalRGBA(red: 0, green: 0, blue: 0)

    public func normalized() -> TerminalRGBA {
        TerminalRGBA(
            red: min(max(red, 0), 1),
            green: min(max(green, 0), 1),
            blue: min(max(blue, 0), 1),
            alpha: min(max(alpha, 0), 1)
        )
    }
}

public enum TerminalPixelMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case native
    case fixed

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum TerminalScaleMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case fit
    case fill
    case stretch

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public struct TerminalCommandConfiguration: Codable, Equatable, Sendable {
    public var catalogItemID: String?
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var environment: [String: String]

    public init(
        catalogItemID: String? = nil,
        executable: String = "",
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String] = [:]
    ) {
        self.catalogItemID = catalogItemID
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

public struct TerminalRenderConfiguration: Codable, Equatable, Sendable {
    public var pixelMode: TerminalPixelMode
    public var fixedWidth: Int?
    public var fixedHeight: Int?
    public var columns: Int?
    public var rows: Int?
    public var fontFamily: String
    public var fontSize: Double
    public var cellSpacing: Double
    public var maxFPS: Int
    public var scaleMode: TerminalScaleMode
    public var background: TerminalRGBA
    public var backgroundOpacity: Double
    public var textScale: Double

    public init(
        pixelMode: TerminalPixelMode = .native,
        fixedWidth: Int? = nil,
        fixedHeight: Int? = nil,
        columns: Int? = nil,
        rows: Int? = nil,
        fontFamily: String = "System Monospace",
        fontSize: Double = 14,
        cellSpacing: Double = 0,
        maxFPS: Int = 30,
        scaleMode: TerminalScaleMode = .fit,
        background: TerminalRGBA = .black,
        backgroundOpacity: Double = 1,
        textScale: Double = 1.5
    ) {
        self.pixelMode = pixelMode
        self.fixedWidth = fixedWidth
        self.fixedHeight = fixedHeight
        self.columns = columns
        self.rows = rows
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.cellSpacing = cellSpacing
        self.maxFPS = maxFPS
        self.scaleMode = scaleMode
        self.background = background
        self.backgroundOpacity = backgroundOpacity
        self.textScale = textScale
    }

    private enum CodingKeys: String, CodingKey {
        case pixelMode
        case fixedWidth
        case fixedHeight
        case columns
        case rows
        case fontFamily
        case fontSize
        case cellSpacing
        case maxFPS
        case scaleMode
        case background
        case backgroundOpacity
        case textScale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.pixelMode = try container.decodeIfPresent(TerminalPixelMode.self, forKey: .pixelMode) ?? .native
        self.fixedWidth = try container.decodeIfPresent(Int.self, forKey: .fixedWidth)
        self.fixedHeight = try container.decodeIfPresent(Int.self, forKey: .fixedHeight)
        self.columns = try container.decodeIfPresent(Int.self, forKey: .columns)
        self.rows = try container.decodeIfPresent(Int.self, forKey: .rows)
        self.fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily) ?? "System Monospace"
        self.fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 14
        self.cellSpacing = try container.decodeIfPresent(Double.self, forKey: .cellSpacing) ?? 0
        self.maxFPS = try container.decodeIfPresent(Int.self, forKey: .maxFPS) ?? 30
        self.scaleMode = try container.decodeIfPresent(TerminalScaleMode.self, forKey: .scaleMode) ?? .fit
        self.background = try container.decodeIfPresent(TerminalRGBA.self, forKey: .background) ?? .black
        self.backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 1
        self.textScale = try container.decodeIfPresent(Double.self, forKey: .textScale) ?? 1.5
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pixelMode, forKey: .pixelMode)
        try container.encodeIfPresent(fixedWidth, forKey: .fixedWidth)
        try container.encodeIfPresent(fixedHeight, forKey: .fixedHeight)
        try container.encodeIfPresent(columns, forKey: .columns)
        try container.encodeIfPresent(rows, forKey: .rows)
        try container.encode(fontFamily, forKey: .fontFamily)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(cellSpacing, forKey: .cellSpacing)
        try container.encode(maxFPS, forKey: .maxFPS)
        try container.encode(scaleMode, forKey: .scaleMode)
        try container.encode(background, forKey: .background)
        try container.encode(backgroundOpacity, forKey: .backgroundOpacity)
        try container.encode(textScale, forKey: .textScale)
    }

    public var effectiveFontSize: Double {
        fontSize * textScale
    }

    public func normalized() -> TerminalRenderConfiguration {
        var result = self
        result.fixedWidth = fixedWidth.map { min(max($0, 320), 16_384) }
        result.fixedHeight = fixedHeight.map { min(max($0, 240), 16_384) }
        result.columns = columns.map { min(max($0, 1), 1000) }
        result.rows = rows.map { min(max($0, 1), 500) }
        result.fontFamily = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.fontFamily.isEmpty { result.fontFamily = "System Monospace" }
        result.fontSize = min(max(fontSize, 6), 96)
        result.cellSpacing = min(max(cellSpacing, 0), 8)
        result.maxFPS = min(max(maxFPS, 1), 120)
        result.textScale = min(max(textScale, 0.5), 3)
        result.background = background.normalized()
        result.backgroundOpacity = min(max(backgroundOpacity, 0), 1)
        if result.pixelMode == .fixed {
            result.fixedWidth = result.fixedWidth ?? 1920
            result.fixedHeight = result.fixedHeight ?? 1080
        }
        return result
    }
}

public struct TerminalWallpaperBehavior: Codable, Equatable, Sendable {
    public var launchAtLogin: Bool
    public var allDisplays: Bool

    public init(launchAtLogin: Bool = false, allDisplays: Bool = true) {
        self.launchAtLogin = launchAtLogin
        self.allDisplays = allDisplays
    }
}

public struct TerminalWallpaperConfig: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var command: TerminalCommandConfiguration
    public var render: TerminalRenderConfiguration
    public var behavior: TerminalWallpaperBehavior

    public init(
        schemaVersion: Int = TerminalWallpaperConfig.currentSchemaVersion,
        command: TerminalCommandConfiguration = TerminalCommandConfiguration(),
        render: TerminalRenderConfiguration = TerminalRenderConfiguration(),
        behavior: TerminalWallpaperBehavior = TerminalWallpaperBehavior()
    ) {
        self.schemaVersion = schemaVersion
        self.command = command
        self.render = render
        self.behavior = behavior
    }

    public static let defaultConfig = TerminalWallpaperConfig()

    public func normalized() -> TerminalWallpaperConfig {
        var result = self
        result.schemaVersion = Self.currentSchemaVersion
        result.command.executable = command.executable.trimmingCharacters(in: .whitespacesAndNewlines)
        if let workingDirectory = command.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), !workingDirectory.isEmpty {
            result.command.workingDirectory = workingDirectory
        } else {
            result.command.workingDirectory = nil
        }
        result.render = render.normalized()
        return result
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case command
        case render
        case behavior
    }
}

public enum TerminalWallpaperCommandAction: String, Codable, Sendable {
    case start
    case stop
    case restart
    case update
    case resize
    case terminate
}

public struct TerminalWallpaperRuntimeCommand: Codable, Equatable, Sendable {
    public var id: String
    public var action: TerminalWallpaperCommandAction
    public var config: TerminalWallpaperConfig?
    public var createdAt: Double

    public init(
        id: String = UUID().uuidString,
        action: TerminalWallpaperCommandAction,
        config: TerminalWallpaperConfig? = nil,
        createdAt: Double = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.action = action
        self.config = config
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case action
        case config
        case createdAt = "created_at"
    }
}

public struct TerminalWallpaperHealth: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var available: Bool
    public var fresh: Bool
    public var running: Bool
    public var childRunning: Bool
    public var childPID: Int?
    public var screens: Int
    public var columns: Int?
    public var rows: Int?
    public var frames: Int
    public var renderedFrames: Int
    public var lastError: String?
    public var updatedAt: Double

    public init(
        available: Bool = false,
        fresh: Bool = false,
        running: Bool = false,
        childRunning: Bool = false,
        childPID: Int? = nil,
        screens: Int = 0,
        columns: Int? = nil,
        rows: Int? = nil,
        frames: Int = 0,
        renderedFrames: Int = 0,
        lastError: String? = nil,
        updatedAt: Double = Date().timeIntervalSince1970
    ) {
        self.schemaVersion = TerminalWallpaperConfig.currentSchemaVersion
        self.available = available
        self.fresh = fresh
        self.running = running
        self.childRunning = childRunning
        self.childPID = childPID
        self.screens = screens
        self.columns = columns
        self.rows = rows
        self.frames = frames
        self.renderedFrames = renderedFrames
        self.lastError = lastError
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case available
        case fresh
        case running
        case childRunning = "child_running"
        case childPID = "child_pid"
        case screens
        case columns
        case rows
        case frames
        case renderedFrames = "rendered_frames"
        case lastError = "last_error"
        case updatedAt = "updated_at"
    }
}

public struct TerminalWallpaperStatus: Codable, Equatable, Sendable {
    public var running: Bool
    public var paused: Bool
    public var pid: Int?
    public var config: TerminalWallpaperConfig
    public var health: TerminalWallpaperHealth?

    public init(
        running: Bool,
        paused: Bool = false,
        pid: Int? = nil,
        config: TerminalWallpaperConfig,
        health: TerminalWallpaperHealth? = nil
    ) {
        self.running = running
        self.paused = paused
        self.pid = pid
        self.config = config
        self.health = health
    }
}
