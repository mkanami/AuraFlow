import Foundation

/// Explicit, documented capabilities. Unknown commands never get guessed flags
/// or a substitute clock. Add a profile only after verifying the program's API.
public enum TerminalNativeSpeed: String, Sendable {
    case cmatrix, lavat, pipes, neo

    public static func profile(for command: TerminalCommandConfiguration) -> Self? {
        if let id = command.catalogItemID, TerminalWallpaperCatalog.item(id: id) != nil {
            // PTY resolution uses the catalog ID, not the editable path.
            switch id {
            case "cmatrix": return .cmatrix
            case "lavat": return .lavat
            case "pipes": return .pipes
            default: return nil
            }
        }
        switch URL(fileURLWithPath: command.executable).lastPathComponent {
        case "cmatrix": return .cmatrix
        case "lavat": return .lavat
        case "pipes.sh": return .pipes
        case "neo": return .neo
        default: return nil
        }
    }

    private var flag: Character {
        switch self { case .cmatrix: return "u"; case .lavat: return "s"; case .pipes: return "f"; case .neo: return "S" }
    }
    private var defaultValue: Double {
        switch self { case .cmatrix: return 4; case .lavat: return 5; case .pipes: return 75; case .neo: return 8 }
    }
    private var bounds: ClosedRange<Double> {
        switch self { case .cmatrix: return 0...10; case .lavat: return 1...10; case .pipes: return 20...100; case .neo: return 0.01...1_000_000 }
    }
    private var valueOptions: Set<Character> {
        switch self {
        case .cmatrix: return Set("uC")
        case .lavat: return Set("cksrRbFp")
        case .pipes: return Set("ptcfsr")
        case .neo: return Set("AbCcdfGglMmrS")
        }
    }

    private struct Options {
        var retained: [String] = []
        var speed: Double?
        var screensaver = false
    }

    // Parse native getopt forms, including combined short flags. Never rewrite
    // strings inside another option's value or arguments following `--`.
    private func options(_ arguments: [String]) -> Options {
        var result = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                result.retained += [argument] + arguments[index...]
                break
            }
            if self == .neo, argument == "--speed" || argument.hasPrefix("--speed=") {
                if argument == "--speed", index < arguments.count {
                    result.speed = Double(arguments[index]); index += 1
                } else { result.speed = Double(argument.dropFirst("--speed=".count)) }
                continue
            }
            guard argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.count > 1 else {
                result.retained.append(argument)
                // Neo's other long value options must keep their values intact.
                if self == .neo, Self.neoLongValueOptions.contains(argument), index < arguments.count {
                    result.retained.append(arguments[index]); index += 1
                }
                continue
            }
            let characters = Array(argument.dropFirst())
            var retained = "-"
            for offset in characters.indices {
                let option = characters[offset]
                if self == .cmatrix, option == "s" { result.screensaver = true }
                guard valueOptions.contains(option) else { retained.append(option); continue }
                let attached = String(characters.dropFirst(offset + 1))
                let value: String?
                if !attached.isEmpty { value = attached }
                else if index < arguments.count { value = arguments[index]; index += 1 }
                else { value = nil }
                if option == flag { result.speed = value.flatMap(Double.init) }
                else {
                    retained.append(option)
                    if !attached.isEmpty { retained += attached }
                    else if let value {
                        result.retained.append(retained)
                        result.retained.append(value)
                        retained = "-"
                    }
                }
                break
            }
            if retained != "-" { result.retained.append(retained) }
        }
        return result
    }

    private static let neoLongValueOptions: Set<String> = [
        "--bold", "--chars", "--color", "--colorfile", "--density", "--fps",
        "--glitchms", "--glitchpct", "--lingerms", "--maxdpc", "--rippct",
        "--charset", "--colormode", "--message", "--shadingmode", "--shortpct"
    ]

    public func value(for config: TerminalWallpaperConfig) -> Double {
        let base = options(config.command.arguments).speed ?? defaultValue
        let requested = config.nativeSpeed ?? (self == .cmatrix
            ? base / config.playbackSpeed : base * config.playbackSpeed)
        let finite = requested.isFinite ? requested : defaultValue
        let bounded = min(max(finite, bounds.lowerBound), bounds.upperBound)
        return self == .neo ? bounded : bounded.rounded()
    }

    public func sliderRange(for config: TerminalWallpaperConfig) -> ClosedRange<Double> {
        guard self == .neo else { return bounds }
        let configured = options(config.command.arguments).speed ?? defaultValue
        let base = configured.isFinite ? min(max(configured, bounds.lowerBound), bounds.upperBound) : defaultValue
        // Derive limits from launch arguments, never from the moving knob.
        return min(1, base)...min(bounds.upperBound, max(64, base * 4))
    }
    public func sliderValue(for config: TerminalWallpaperConfig) -> Double {
        let native = value(for: config)
        return self == .cmatrix ? 10 - native : native
    }
    public func nativeValue(fromSlider value: Double) -> Double {
        self == .cmatrix ? 10 - value : value
    }
    public func label(for config: TerminalWallpaperConfig) -> String {
        let native = value(for: config)
        switch self {
        case .cmatrix: return "\(Int(native) * 10) ms"
        case .lavat: return "\(Int(native))/10"
        case .pipes: return "\(Int(native)) fps"
        case .neo: return "\(String(format: "%g", native)) ch/s"
        }
    }

    public static func launchCommand(for config: TerminalWallpaperConfig) -> TerminalCommandConfiguration {
        guard let profile = profile(for: config.command) else { return config.command }
        var command = config.command
        var arguments = profile.options(command.arguments).retained
        arguments.insert(contentsOf: ["-\(profile.flag)", String(format: "%g", profile.value(for: config))], at: 0)
        command.arguments = arguments
        return command
    }

    /// nil means restart, not an unsupported or silently ignored live update.
    public func input(for config: TerminalWallpaperConfig) -> Data? {
        let native = value(for: config)
        guard self == .cmatrix, native <= 9, !options(config.command.arguments).screensaver else { return nil }
        return Data(String(Int(native)).utf8)
    }

    public static func changed(from old: TerminalWallpaperConfig, to new: TerminalWallpaperConfig) -> Bool {
        guard old.command == new.command, let profile = profile(for: new.command) else { return false }
        return profile.value(for: old) != profile.value(for: new)
    }
}
