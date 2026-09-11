import Foundation

enum UserFacingMessageFormatter {
    static func format(_ message: String) -> String {
        guard let lastContentIndex = message.lastIndex(where: {
            !$0.isWhitespace
        }),
        message[lastContentIndex] == "."
        else {
            return message
        }

        let contentBeforePeriod = message[..<lastContentIndex]
        if contentBeforePeriod.last == "." {
            return message
        }

        let trailingWhitespace = message[message.index(after: lastContentIndex)...]
        return String(contentBeforePeriod) + trailingWhitespace
    }
}
