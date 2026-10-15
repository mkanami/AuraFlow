import AppKit
import Foundation
import AuraTerminalWallpaperCore

protocol TerminalWallpaperInstalling: Sendable {
    var homebrewAvailable: Bool { get }
    func prepareHomebrew(onStage: @escaping @Sendable (String) -> Void) async throws
    func install(
        preset: TerminalWallpaperPreset,
        onStage: @escaping @Sendable (String) -> Void
    ) async throws
}

extension TerminalWallpaperInstalling {
    var homebrewAvailable: Bool { true }
    func prepareHomebrew(onStage: @escaping @Sendable (String) -> Void) async throws {}
}

enum TerminalWallpaperInstallError: LocalizedError {
    case unsupportedHomebrewPlatform
    case invalidPreset
    case downloadFailed
    case invalidPackage
    case installerCouldNotOpen
    case homebrewDidNotAppear
    case commandFailed(String)
    case executableStillMissing
    case homebrewRequired

    var errorDescription: String? {
        switch self {
        case .unsupportedHomebrewPlatform:
            return "Automatic Homebrew setup needs Apple Silicon and macOS 15 or newer. See docs.brew.sh/Installation."
        case .invalidPreset:
            return "Choose a valid terminal program from the search results."
        case .downloadFailed:
            return "Could not download the official Homebrew installer. Try again."
        case .invalidPackage:
            return "The Homebrew installer could not be verified. Nothing was installed."
        case .installerCouldNotOpen:
            return "macOS could not open the Homebrew installer."
        case .homebrewDidNotAppear:
            return "Homebrew setup was not completed. Finish it in Installer, then try again."
        case .commandFailed(let detail):
            return "Homebrew could not install this wallpaper: \(detail)"
        case .executableStillMissing:
            return "Installation finished, but the wallpaper executable is not available."
        case .homebrewRequired:
            return "Homebrew is required. Set it up first, then install this animation."
        }
    }
}

/// Installs validated Homebrew core formulae. Search text and manually selected
/// executable paths never become package-manager arguments.
final class SystemTerminalWallpaperInstaller: TerminalWallpaperInstalling {
    typealias CommandRunner = @Sendable (
        String, [String], [String: String], @escaping @Sendable (String) -> Void
    ) async throws -> (code: Int32, output: String)
    private let packageProvider: any TerminalAnimationPackageProviding
    private let resolveExecutable: @Sendable (TerminalWallpaperCatalogItem) -> String?
    private let resolveBrew: @Sendable () -> String?
    private let runCommand: CommandRunner

    init(
        packageProvider: any TerminalAnimationPackageProviding = SystemTerminalAnimationPackageProvider.shared,
        resolveExecutable: @escaping @Sendable (TerminalWallpaperCatalogItem) -> String? = { $0.resolvedExecutable() },
        resolveBrew: @escaping @Sendable () -> String? = { SystemTerminalWallpaperInstaller.brewExecutable() },
        runCommand: @escaping CommandRunner = { executable, arguments, environment, output in
            try await SystemTerminalWallpaperInstaller.run(executable, arguments: arguments, environment: environment, onOutput: output)
        }
    ) {
        self.packageProvider = packageProvider
        self.resolveExecutable = resolveExecutable
        self.resolveBrew = resolveBrew
        self.runCommand = runCommand
    }

    var homebrewAvailable: Bool { resolveBrew() != nil }

    /// Scoped to this command, not the user's global Homebrew settings.
    /// Normal bottle selection, checksums and dependency/linkage checks remain.
    static let installationEnvironment = [
        "HOMEBREW_NO_AUTO_UPDATE": "1",
        "HOMEBREW_NO_INSTALL_CLEANUP": "1",
        "HOMEBREW_NO_INSTALL_UPGRADE": "1",
        "HOMEBREW_NO_ANALYTICS": "1",
    ]

    func prepareHomebrew(onStage: @escaping @Sendable (String) -> Void) async throws {
        guard !homebrewAvailable else { return }
        _ = try await installHomebrew(onStage: onStage)
    }

    func install(
        preset: TerminalWallpaperPreset,
        onStage: @escaping @Sendable (String) -> Void
    ) async throws {
        guard preset.isValid, !preset.formula.isEmpty else { throw TerminalWallpaperInstallError.invalidPreset }
        try Task.checkCancellation()
        // Another operation may have finished while metadata was being checked.
        // An installed executable needs neither the network nor a brew process.
        if resolveExecutable(preset.item) != nil { return }
        let metadata = try await packageProvider.metadata(for: preset)
        guard !metadata.disabled, metadata.name == preset.formula,
              metadata.executables?.contains(preset.executableName) == true else {
            throw TerminalAnimationPackageError.invalidResponse
        }

        try Task.checkCancellation()
        if resolveExecutable(preset.item) != nil { return }
        guard let brew = resolveBrew() else { throw TerminalWallpaperInstallError.homebrewRequired }

        onStage("Installing \(preset.item.title)…")
        let progress = TerminalInstallProgressReporter(onStage: onStage)
        let result = try await runCommand(
            brew,
            ["install", "--formula", "homebrew/core/\(preset.formula)"],
            Self.installationEnvironment,
            { progress.receive($0) }
        )
        guard result.code == 0 else {
            throw TerminalWallpaperInstallError.commandFailed(
                String(result.output.suffix(500)).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        try Task.checkCancellation()
        guard resolveExecutable(preset.item) != nil else {
            throw TerminalWallpaperInstallError.executableStillMissing
        }
    }

    private func installHomebrew(
        onStage: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        var system = utsname()
        uname(&system)
        let machine = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        guard machine == "arm64", ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 else {
            throw TerminalWallpaperInstallError.unsupportedHomebrewPlatform
        }

        let url = URL(string: "https://github.com/Homebrew/brew/releases/latest/download/Homebrew.pkg")!
        let (download, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TerminalWallpaperInstallError.downloadFailed
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuraFlow-Homebrew-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = directory.appendingPathComponent("Homebrew.pkg")
        try FileManager.default.moveItem(at: download, to: package)

        let signature = try await Self.run("/usr/sbin/pkgutil", arguments: ["--check-signature", package.path])
        let assessment = try await Self.run("/usr/sbin/spctl", arguments: ["--assess", "--type", "install", package.path])
        guard signature.code == 0,
              signature.output.contains("Developer ID Installer"),
              assessment.code == 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw TerminalWallpaperInstallError.invalidPackage
        }

        onStage("Finish Homebrew setup in macOS Installer…")
        let opened = await MainActor.run { NSWorkspace.shared.open(package) }
        guard opened else {
            try? FileManager.default.removeItem(at: directory)
            throw TerminalWallpaperInstallError.installerCouldNotOpen
        }

        for _ in 0..<300 {
            try Task.checkCancellation()
            if let brew = Self.brewExecutable(),
               let result = try? await Self.run(brew, arguments: ["--version"]),
               result.code == 0 {
                try? FileManager.default.removeItem(at: directory)
                return brew
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw TerminalWallpaperInstallError.homebrewDidNotAppear
    }

    private static func brewExecutable() -> String? {
        TerminalWallpaperCatalogItem(
            id: "homebrew", title: "Homebrew", subtitle: "", category: .utilities,
            systemImage: "terminal", executableCandidates: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew", "brew"]
        ).resolvedExecutable()
    }

    static func run(
        _ executable: String,
        arguments: [String],
        environment extraEnvironment: [String: String] = [:],
        onOutput: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> (code: Int32, output: String) {
        let operation = TerminalInstallCommandOperation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await operation.run(executable: executable, arguments: arguments, environment: extraEnvironment,
                                           onOutput: onOutput)
        } onCancel: { operation.cancel() }
    }
}

/// Bounded streaming progress, deduplicated before reaching the main actor.
final class TerminalInstallProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = ""
    private var lastStage: String?
    private let onStage: @Sendable (String) -> Void

    init(onStage: @escaping @Sendable (String) -> Void) { self.onStage = onStage }

    func receive(_ output: String) {
        lock.lock()
        defer { lock.unlock() }
        tail = String((tail + output).suffix(4096))
        let lines = tail.components(separatedBy: .newlines)
        tail = lines.last ?? ""
        let stage = lines.dropLast().compactMap(Self.stage(for:)).last
        if let stage, stage != lastStage {
            lastStage = stage
            onStage(stage)
        }
    }

    static func stage(for line: String) -> String? {
        if line.contains("Downloading") || line.contains("Fetching") { return "Downloading packages…" }
        if line.contains("Installing dependencies") || line.contains("Installing dependency") { return "Installing dependencies…" }
        if line.contains("Pouring") { return "Installing prebuilt package…" }
        if line.contains("==> make") || line.contains("==> cmake") || line.contains("==> gem") { return "Building package…" }
        if line.contains("Installing") { return "Installing package…" }
        return nil
    }
}
