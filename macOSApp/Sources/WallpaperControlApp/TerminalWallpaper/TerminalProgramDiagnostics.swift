import Foundation

enum TerminalProgramDiagnostics {
    static func lines(_ output: String) -> [String] {
        let text = String(output.prefix(65_536))
            .replacingOccurrences(of: #"\x1b\][^\x07]*(?:\x07|\x1b\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1b\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func summary(_ output: String) -> String {
        let values = lines(output)
        let reason = values.first { $0.range(of: #"(?i)(?:^|: )(?:error\b|fatal\b|no .*(?:specified|required)|missing\b|invalid (?:option|argument)|unknown option|unrecognized option|permission denied)"#, options: .regularExpression) != nil }
        return String((reason ?? values.prefix(3).joined(separator: " ")).prefix(400))
    }

    static func isHelpOrPrompt(_ output: String) -> Bool {
        lines(output).prefix(5).contains {
            $0.range(of: #"(?i)^\s*(?:usage\s*:|(?:enter|provide)\s+(?:a\s+|the\s+|your\s+)?(?:password|filename|file path|pattern|url)|password\s*:|no pattern specified)"#, options: .regularExpression) != nil
        }
    }
}
