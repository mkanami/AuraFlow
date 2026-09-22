import Foundation

public struct VTParser {
    public private(set) var grid: TerminalGrid

    private enum State {
        case ground
        case escape
        case escapeIntermediate
        case csi
        case osc
        case oscEscape
    }

    private var state: State = .ground
    private var csiParameters = ""
    private var csiPrivate = false
    private var utf8Buffer: [UInt8] = []
    private var utf8Expected = 0
    private var savedStyle = TerminalCellStyle()

    public init(columns: Int, rows: Int) {
        grid = TerminalGrid(columns: columns, rows: rows)
    }

    public mutating func resize(columns: Int, rows: Int) {
        grid.resize(columns: columns, rows: rows)
    }

    public mutating func feed(_ data: Data) {
        for byte in data {
            consume(byte)
        }
    }

    public mutating func reset() {
        grid.reset()
        state = .ground
        csiParameters = ""
        csiPrivate = false
        utf8Buffer.removeAll(keepingCapacity: true)
        utf8Expected = 0
        savedStyle = TerminalCellStyle()
    }

    private mutating func consume(_ byte: UInt8) {
        switch state {
        case .ground:
            consumeGround(byte)
        case .escape:
            consumeEscape(byte)
        case .escapeIntermediate:
            consumeEscapeIntermediate(byte)
        case .csi:
            consumeCSI(byte)
        case .osc:
            if byte == 0x07 {
                state = .ground
            } else if byte == 0x1B {
                state = .oscEscape
            }
        case .oscEscape:
            state = byte == 0x5C ? .ground : .osc
        }
    }

    private mutating func consumeGround(_ byte: UInt8) {
        switch byte {
        case 0x1B:
            flushUTF8IfNeeded()
            state = .escape
        case 0x00...0x08, 0x0B...0x0C, 0x0E...0x1A, 0x1C...0x1F:
            flushUTF8IfNeeded()
            consumeControl(byte)
        case 0x09:
            flushUTF8IfNeeded()
            grid.tab()
        case 0x0A:
            flushUTF8IfNeeded()
            grid.lineFeed()
        case 0x0D:
            flushUTF8IfNeeded()
            grid.carriageReturn()
        case 0x7F:
            break
        case 0x80...0xFF:
            consumeUTF8(byte)
        default:
            grid.put(String(UnicodeScalar(byte)))
        }
    }

    private mutating func consumeControl(_ byte: UInt8) {
        switch byte {
        case 0x08:
            grid.backspace()
        case 0x0B, 0x0C, 0x18, 0x1A:
            break
        default:
            break
        }
    }

    private mutating func consumeEscape(_ byte: UInt8) {
        switch byte {
        case 0x5B:
            csiParameters = ""
            csiPrivate = false
            state = .csi
        case 0x5D:
            state = .osc
        case 0x37:
            grid.saveCursor()
            state = .ground
        case 0x38:
            grid.restoreCursor()
            state = .ground
        case 0x63:
            grid.reset()
            savedStyle = TerminalCellStyle()
            state = .ground
        case 0x44:
            grid.lineFeed()
            state = .ground
        case 0x45:
            grid.lineFeed()
            grid.carriageReturn()
            state = .ground
        case 0x4D:
            state = .ground
        case 0x48:
            state = .ground
        case 0x20...0x2F:
            // ESC sequences can contain intermediate bytes before their
            // final byte (for example ESC ( B selects the ASCII character set).
            // Consume the full sequence so its final byte is not rendered as text.
            state = .escapeIntermediate
        default:
            state = .ground
        }
    }

    private mutating func consumeEscapeIntermediate(_ byte: UInt8) {
        if byte == 0x1B {
            state = .escape
        } else if !(0x20...0x2F).contains(byte) {
            state = .ground
        }
    }

    private mutating func consumeCSI(_ byte: UInt8) {
        if byte == 0x3F && csiParameters.isEmpty {
            csiPrivate = true
            return
        }
        if byte >= 0x30 && byte <= 0x3F {
            csiParameters.append(Character(UnicodeScalar(byte)))
            return
        }
        if byte >= 0x20 && byte <= 0x2F {
            return
        }
        guard byte >= 0x40 && byte <= 0x7E else {
            state = .ground
            return
        }
        let parameters = csiParameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        applyCSI(final: byte, parameters: parameters)
        state = .ground
    }

    private mutating func applyCSI(final: UInt8, parameters: [Int]) {
        let first = parameters.first ?? 0
        let defaultOne = first == 0 ? 1 : first
        switch final {
        case 0x41:
            grid.moveCursor(row: grid.cursorRow - defaultOne)
        case 0x42, 0x65:
            grid.moveCursor(row: grid.cursorRow + defaultOne)
        case 0x43, 0x61:
            grid.moveCursor(column: grid.cursorColumn + defaultOne)
        case 0x44:
            grid.moveCursor(column: grid.cursorColumn - defaultOne)
        case 0x45:
            grid.moveCursor(column: 0, row: grid.cursorRow + defaultOne)
        case 0x46:
            grid.moveCursor(column: 0, row: grid.cursorRow - defaultOne)
        case 0x47, 0x60:
            grid.moveCursor(column: max(first - 1, 0))
        case 0x48, 0x66:
            let row = max((parameters.first ?? 1) - 1, 0)
            let column = max((parameters.dropFirst().first ?? 1) - 1, 0)
            grid.moveCursor(column: column, row: row)
        case 0x64:
            grid.moveCursor(row: max(first - 1, 0))
        case 0x4A:
            grid.eraseDisplay(mode: first)
        case 0x4B:
            grid.eraseLine(mode: first)
        case 0x6D:
            applySGR(parameters)
        case 0x72:
            let top = max((parameters.first ?? 1) - 1, 0)
            let bottom = max((parameters.dropFirst().first ?? 0) - 1, top)
            grid.setScrollRegion(top: top, bottom: bottom)
        case 0x73:
            grid.saveCursor()
        case 0x75:
            grid.restoreCursor()
        case 0x68:
            applyMode(enabled: true, parameters: parameters)
        case 0x6C:
            applyMode(enabled: false, parameters: parameters)
        default:
            break
        }
    }

    private mutating func applyMode(enabled: Bool, parameters: [Int]) {
        for parameter in parameters {
            if csiPrivate && parameter == 1049 {
                if enabled { grid.enterAlternateScreen() } else { grid.leaveAlternateScreen() }
            } else if csiPrivate && parameter == 25 {
                grid.setCursorVisible(enabled)
            }
        }
    }

    private mutating func applySGR(_ parameters: [Int]) {
        let values = parameters.isEmpty ? [0] : parameters
        var style = savedStyle
        var index = 0
        while index < values.count {
            let value = values[index]
            switch value {
            case 0:
                style = TerminalCellStyle()
            case 1:
                style.attributes.insert(.bold)
            case 2:
                style.attributes.insert(.dim)
            case 4:
                style.attributes.insert(.underline)
            case 7:
                style.attributes.insert(.inverse)
            case 22:
                style.attributes.remove([.bold, .dim])
            case 24:
                style.attributes.remove(.underline)
            case 27:
                style.attributes.remove(.inverse)
            case 30...37:
                style.foreground = .indexed(UInt8(value - 30))
            case 39:
                style.foreground = .default
            case 40...47:
                style.background = .indexed(UInt8(value - 40))
            case 49:
                style.background = .default
            case 90...97:
                style.foreground = .indexed(UInt8(value - 90 + 8))
            case 100...107:
                style.background = .indexed(UInt8(value - 100 + 8))
            case 38, 48:
                let isForeground = value == 38
                if index + 2 < values.count, values[index + 1] == 5 {
                    let color = TerminalColor.indexed(UInt8(min(max(values[index + 2], 0), 255)))
                    if isForeground { style.foreground = color } else { style.background = color }
                    index += 2
                } else if index + 4 < values.count, values[index + 1] == 2 {
                    let color = TerminalColor.rgb(
                        UInt8(min(max(values[index + 2], 0), 255)),
                        UInt8(min(max(values[index + 3], 0), 255)),
                        UInt8(min(max(values[index + 4], 0), 255))
                    )
                    if isForeground { style.foreground = color } else { style.background = color }
                    index += 4
                }
            default:
                break
            }
            index += 1
        }
        savedStyle = style
        grid.setStyle(style)
    }

    private mutating func consumeUTF8(_ byte: UInt8) {
        if utf8Buffer.isEmpty {
            utf8Expected = byte < 0xE0 ? 2 : (byte < 0xF0 ? 3 : 4)
        }
        utf8Buffer.append(byte)
        guard utf8Buffer.count >= utf8Expected else { return }
        let text = String(decoding: utf8Buffer, as: UTF8.self)
        if let character = text.first {
            grid.put(String(character))
        }
        utf8Buffer.removeAll(keepingCapacity: true)
        utf8Expected = 0
    }

    private mutating func flushUTF8IfNeeded() {
        guard !utf8Buffer.isEmpty else { return }
        grid.put("�")
        utf8Buffer.removeAll(keepingCapacity: true)
        utf8Expected = 0
    }
}
