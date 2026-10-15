import AuraTerminalWallpaperCore
import CryptoKit
import Darwin
import Foundation

protocol TerminalProgramAnimationResolving: Sendable {
    func resolve(_ command: TerminalCommandConfiguration) async throws -> TerminalCommandConfiguration
    func reject(_ command: TerminalCommandConfiguration) async
}

/// Runs only after an explicit Preview action. Documentation is data, never a
/// downloaded command. Known presets and all explicit arguments remain intact.
actor SystemTerminalProgramAnimationResolver: TerminalProgramAnimationResolving {
    static let shared = SystemTerminalProgramAnimationResolver()
    private struct Record: Codable {
        let date: Date
        let help: String
        let arguments: [String]?
    }
    private var records: [String: Record] = [:]
    private var loaded = false
    private let cacheURL: URL?
    private let probe: @Sendable (String, [String], TerminalCommandConfiguration) async throws -> String?

    init(cacheURL: URL? = TerminalWallpaperRuntimeStore.defaultAppSupportURL().appendingPathComponent("animation-options-cache.json"),
         probe: @escaping @Sendable (String, [String], TerminalCommandConfiguration) async throws -> String? = {
             try await TerminalAnimationHelpProbe.read(executable: $0, arguments: $1,
                 environment: $2.environment, workingDirectory: $2.workingDirectory)
         }) {
        self.cacheURL = cacheURL
        self.probe = probe
    }

    func resolve(_ command: TerminalCommandConfiguration) async throws -> TerminalCommandConfiguration {
        try Task.checkCancellation()
        guard command.arguments.isEmpty else { return command }
        guard let executable = TerminalExecutableLocator.resolve(command.executable),
              !Self.hasReviewedDefaults(executable), let key = Self.fingerprint(executable, command: command) else { return command }
        try Task.checkCancellation()
        load()
        if let record = records[key], Date().timeIntervalSince(record.date) < (record.arguments == nil ? 60 : 86_400),
           record.arguments == TerminalAnimationOptionParser.arguments(in: record.help) {
            return Self.applying(record.arguments, to: command)
        }
        var environment = TerminalProcessEnvironment.make(overrides: command.environment, executable: executable, columns: 80, rows: 24)
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        environment["PAGER"] = "/bin/cat"
        environment["MANPAGER"] = "/bin/cat"
        var helpCommand = command
        helpCommand.environment = environment
        var documentation = ""
        // A separate help probe cannot write files, contact the network, use
        // audio, fork children or signal other processes. Never run bare CLI
        // output repeatedly to see whether it might become animated.
        for option in ["--help", "-h"] {
            try Task.checkCancellation()
            if let help = try await probe(executable, [option], helpCommand) {
                documentation = help
                if let arguments = TerminalAnimationOptionParser.arguments(in: help) {
                    try Task.checkCancellation()
                    // Do not associate documentation with a binary updated
                    // while its help was running.
                    guard Self.fingerprint(executable, command: command) == key else { return command }
                    save(key, help: help, arguments: arguments)
                    return Self.applying(arguments, to: command)
                }
            }
        }
        // Read only the matching executable's local section-1 manual, never
        // traverse the disk or parse random internet shell snippets.
        for url in Self.manualCandidates(executable) {
            try Task.checkCancellation()
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  size.isRegularFile == true, (size.fileSize ?? Int.max) <= 65_536 else { continue }
            let text: String?
            if url.pathExtension == "gz" {
                text = try await probe("/usr/bin/gzip", ["-cd", url.path], helpCommand)
            } else {
                text = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
            }
            if let text, let arguments = TerminalAnimationOptionParser.arguments(in: text) {
                try Task.checkCancellation()
                guard Self.fingerprint(executable, command: command) == key else { return command }
                save(key, help: text, arguments: arguments)
                return Self.applying(arguments, to: command)
            }
        }
        try Task.checkCancellation()
        save(key, help: documentation, arguments: nil)
        return command
    }

    func reject(_ command: TerminalCommandConfiguration) {
        guard let executable = TerminalExecutableLocator.resolve(command.executable),
              let key = Self.fingerprint(executable, command: command) else { return }
        save(key, help: "", arguments: nil)
    }

    private static func applying(_ arguments: [String]?, to command: TerminalCommandConfiguration) -> TerminalCommandConfiguration {
        var result = command
        if let arguments { result.arguments = arguments }
        return result
    }

    static func hasReviewedDefaults(_ executable: String) -> Bool {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        return ["lolcat", "cava"].contains(name) || TerminalWallpaperCatalog.items.contains { item in
            item.executableCandidates.contains { URL(fileURLWithPath: $0).lastPathComponent == name }
        }
    }

    private static func fingerprint(_ executable: String, command: TerminalCommandConfiguration) -> String? {
        let url = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        // Environment values may contain secrets; persist only their digest.
        let identity = [URL(fileURLWithPath: executable).standardizedFileURL.path, url.path,
                        String(modified.timeIntervalSince1970), size.stringValue, inode.stringValue,
                        command.workingDirectory ?? "",
                        command.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func manualCandidates(_ executable: String) -> [URL] {
        let original = URL(fileURLWithPath: executable)
        let name = original.lastPathComponent
        let prefixes = [original, original.resolvingSymlinksInPath()].map { $0.deletingLastPathComponent().deletingLastPathComponent().path }
        var seen = Set<String>()
        return (prefixes + ["/opt/homebrew", "/usr/local", "/usr"]).filter { seen.insert($0).inserted }.flatMap { prefix in
            ["\(name).1", "\(name).1.gz"].map { URL(fileURLWithPath: prefix).appendingPathComponent("share/man/man1/\($0)") }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let cacheURL, let size = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]),
              (size.fileSize ?? Int.max) <= 2_200_000, let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data) else { return }
        records = decoded.filter { $0.value.help.utf8.count <= 65_536 }.reduce(into: [:]) { result, entry in
            if result.count < 32 { result[entry.key] = entry.value }
        }
    }

    private func save(_ key: String, help: String, arguments: [String]?) {
        records[key] = Record(date: Date(), help: help, arguments: arguments)
        if records.count > 32, let oldest = records.min(by: { $0.value.date < $1.value.date })?.key { records.removeValue(forKey: oldest) }
        guard let cacheURL else { return }
        var encoded = try? JSONEncoder().encode(records)
        while (encoded?.count ?? 0) > 2_200_000, records.count > 1 {
            if let oldest = records.filter({ $0.key != key }).min(by: { $0.value.date < $1.value.date })?.key {
                records.removeValue(forKey: oldest)
            }
            encoded = try? JSONEncoder().encode(records)
        }
        guard let data = encoded else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try? data.write(to: cacheURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }
}

/// A conservative visual-option parser. Undocumented values, subcommands, shell
/// examples, negative flags, file-writing watchers and audio modes are not
/// suitable launch defaults. A failed/ambiguous discovery means normal output.
enum TerminalAnimationOptionParser {
    static func flag(in raw: String) -> String? {
        arguments(in: raw)?.first
    }

    static func arguments(in raw: String) -> [String]? {
        guard raw.utf8.count <= 65_536 else { return nil }
        let text = raw.replacingOccurrences(of: #"\x1b\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\\f(?:\[[^\]]*\]|\(.{2}|.)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\-", with: "-")
            .replacingOccurrences(of: "\\&", with: "")
        let lines = text.components(separatedBy: .newlines).map { line -> String in
            let line = line.replacingOccurrences(of: #"^\.(?:B|I|BR|BI|IR|RB)\s+"#, with: "", options: .regularExpression)
            return line.replacingOccurrences(of: "\"", with: "")
        }
        let visualContext = text.range(of: #"(?i)\b(?:ascii|terminal|screen|display|visuali[sz]er|animation|animated)\b|анимаци|экран|терминал"#, options: .regularExpression) != nil
        let pattern = #"^\s*((?:--[a-z][a-z0-9-]*|-[A-Za-z])(?:\s*(?:[,|/]\s*|\s+)(?:--[a-z][a-z0-9-]*|-[A-Za-z]))*)(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var candidates: [([String], Int)] = []
        for (index, line) in lines.enumerated() {
            let ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let names = ns.substring(with: match.range(at: 1))
            let remainder = ns.substring(with: match.range(at: 2))
            guard remainder.isEmpty || remainder.first?.isWhitespace == true || remainder.hasPrefix("=") else { continue }
            var description = remainder.trimmingCharacters(in: .whitespaces)
            // Roff and wrapped help commonly put the description on the next
            // line. Do not consume another option or a commands/examples block.
            if index + 1 < lines.count {
                for next in lines[(index + 1)..<min(index + 4, lines.count)] {
                    let value = next.trimmingCharacters(in: .whitespaces)
                    if value.hasPrefix("-") || value.hasPrefix(".") || value.isEmpty { break }
                    description += " " + value
                }
            }
            let first = description.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            let parameter = first.trimmingCharacters(in: CharacterSet(charactersIn: "=<[]>")).lowercased()
            let requiresValue = first.hasPrefix("=") || first.hasPrefix("<") || first.hasPrefix("[")
                || (first.count > 1 && first == first.uppercased() && first.contains(where: \.isLetter))
                || Double(first) != nil
                || ["int", "float", "number", "seconds", "interval", "count", "bool", "boolean", "mode", "n", "true", "false"].contains(parameter)
            var value: String?
            if requiresValue {
                // Values are never invented. Only explicit boolean choices or
                // a documented static/live animation enum may enable a mode.
                if ["bool", "boolean"].contains(parameter) {
                    value = documentedValue(#"(?i)\b(on)\s*[,|/]\s*off\b"#, in: description)
                        ?? documentedValue(#"(?i)\b(true)\s*[,|/]\s*false\b"#, in: description)
                } else if parameter == "mode" {
                    for mode in ["animated", "animate", "live"] {
                        value = documentedValue("(?i)\\b(?:static\\s*[,|/]\\s*(\(mode))|(\(mode))\\s*[,|/]\\s*static)\\b", in: description)
                        if value != nil { break }
                    }
                }
                guard value != nil else { continue }
            }
            let lower = description.lowercased()
            guard lower.range(of: #"\b(?:animat\w*|continu\w*|live|watch\w*|loop\w*|follow\w*|monitor\w*|refresh\w*)\b|анимаци|непрерыв|обновля|наблюден"#, options: .regularExpression) != nil,
                  lower.range(of: #"\b(?:help|version|list|disable|stop|delete|remove|write|overwrite|save|export|execute|rebuild|reload|sync|upload|download|install|sound|audio|music|microphone)\w*\b|удал|запис|звук|аудио|отключ"#, options: .regularExpression) == nil,
                  (lower.range(of: #"\b(?:enable|start|run|show|display|draw|render|animate|loop|watch|follow|monitor|continuous|continuously|refresh)\b|включ|анимировать|непрерыв|обновля"#, options: .regularExpression) != nil),
                  (visualContext || lower.range(of: #"\b(?:output|display|render|screen|statistics|metrics|cpu|memory|log)\b|вывод|экран"#, options: .regularExpression) != nil) else { continue }
            let flags = names.components(separatedBy: CharacterSet(charactersIn: ",|/ ")).filter { !$0.isEmpty }
            guard let flag = flags.first(where: { $0.hasPrefix("--") }) ?? flags.first,
                  !["-h", "-V", "-v"].contains(flag),
                  flag.range(of: #"^--(?:help|version|list|no-|disable-|without-|stop-|delete|remove|write|save|export|execute|install|sync)"#, options: .regularExpression) == nil else { continue }
            let score = lower.contains("animat") || lower.contains("анимаци") ? 3 : lower.contains("live") ? 2 : 1
            candidates.append(([flag] + (value.map { [$0] } ?? []), score))
        }
        return candidates.sorted { $0.1 == $1.1 ? $0.0.lexicographicallyPrecedes($1.0) : $0.1 > $1.1 }.first?.0
    }

    private static func documentedValue(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        for index in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: text) { return String(text[range]) }
        }
        return nil
    }
}

enum TerminalAnimationHelpProbe {
    static let profile = #"""
    (version 1)
    (allow default)
    (deny file-write*)
    (deny network*)
    (deny process-fork)
    (deny signal)
    (deny mach-lookup)
    (deny iokit-open)
    (deny appleevent-send)
    (deny device-microphone)
    """#

    static func read(executable: String, arguments: [String], environment: [String: String],
                     workingDirectory: String? = nil,
                     timeout: UInt64 = 2_000_000_000) async throws -> String? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { return nil }
        let operation = TerminalInstallCommandOperation()
        let capture = TerminalAnimationHelpCapture()
        let deadline = Task {
            try await Task.sleep(nanoseconds: timeout)
            operation.cancel()
        }
        defer { deadline.cancel() }
        do {
            _ = try await withTaskCancellationHandler {
                try await operation.run(executable: "/usr/bin/sandbox-exec",
                    arguments: ["-p", profile, executable] + arguments, environment: environment,
                    stdinFromNull: true, workingDirectory: workingDirectory) { text in
                        if !capture.append(text) { operation.cancel() }
                    }
            } onCancel: { operation.cancel() }
        } catch {
            try Task.checkCancellation()
            return nil
        }
        try Task.checkCancellation()
        return capture.text
    }
}

private final class TerminalAnimationHelpCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    private var oversized = false
    func append(_ text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if oversized || value.utf8.count + text.utf8.count > 65_536 { oversized = true; return false }
        value += text
        return true
    }
    var text: String? { lock.lock(); defer { lock.unlock() }; return oversized ? nil : value }
}
