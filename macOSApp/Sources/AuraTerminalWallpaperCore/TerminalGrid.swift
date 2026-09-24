import Foundation

public enum TerminalColor: Equatable, Codable, Sendable {
    case `default`
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    public func resolved(defaultColor: TerminalRGBA, palette: [TerminalRGBA]) -> TerminalRGBA {
        switch self {
        case .default:
            return defaultColor
        case .indexed(let index):
            let value = Int(index)
            if value < palette.count {
                return palette[value]
            }
            guard value >= 16 else { return defaultColor }
            if value < 232 {
                // xterm's 6×6×6 color cube (also used by Kitty).
                let cubeIndex = value - 16
                let levels = [0, 95, 135, 175, 215, 255]
                return TerminalRGBA(
                    red: Double(levels[cubeIndex / 36]) / 255,
                    green: Double(levels[(cubeIndex / 6) % 6]) / 255,
                    blue: Double(levels[cubeIndex % 6]) / 255
                )
            }
            if value < 256 {
                let gray = Double(8 + (value - 232) * 10) / 255
                return TerminalRGBA(red: gray, green: gray, blue: gray)
            }
            return defaultColor
        case .rgb(let red, let green, let blue):
            return TerminalRGBA(
                red: Double(red) / 255,
                green: Double(green) / 255,
                blue: Double(blue) / 255
            )
        }
    }
}

public enum TerminalPalette {
    /// Kitty's built-in ANSI palette, used when no application palette is configured.
    public static let kittyDefault16: [TerminalRGBA] = [
        color(0x000000), color(0xCC0403), color(0x19CB00), color(0xCECB00),
        color(0x0D73CC), color(0xCB1ED1), color(0x0DCDCD), color(0xDDDDDD),
        color(0x767676), color(0xF2201F), color(0x23FD00), color(0xFFFD00),
        color(0x1A8FFF), color(0xFD28FF), color(0x14FFFF), color(0xFFFFFF),
    ]

    private static func color(_ rgb: UInt32) -> TerminalRGBA {
        TerminalRGBA(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

public struct TerminalAttributes: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let bold = TerminalAttributes(rawValue: 1 << 0)
    public static let dim = TerminalAttributes(rawValue: 1 << 1)
    public static let underline = TerminalAttributes(rawValue: 1 << 2)
    public static let inverse = TerminalAttributes(rawValue: 1 << 3)
}

public struct TerminalCellStyle: Codable, Equatable, Sendable {
    public var foreground: TerminalColor
    public var background: TerminalColor
    public var attributes: TerminalAttributes

    public init(
        foreground: TerminalColor = .default,
        background: TerminalColor = .default,
        attributes: TerminalAttributes = []
    ) {
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
    }
}

public struct TerminalCell: Codable, Equatable, Sendable {
    public var text: String
    public var style: TerminalCellStyle
    public var width: Int

    public init(text: String = " ", style: TerminalCellStyle = TerminalCellStyle(), width: Int = 1) {
        self.text = text
        self.style = style
        self.width = width
    }
}

public struct TerminalGridSnapshot: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let cells: [TerminalCell]
    public let cursorColumn: Int
    public let cursorRow: Int
    public let cursorVisible: Bool
    public let revision: UInt64

    public init(
        columns: Int,
        rows: Int,
        cells: [TerminalCell],
        cursorColumn: Int,
        cursorRow: Int,
        cursorVisible: Bool,
        revision: UInt64 = 0
    ) {
        self.columns = columns
        self.rows = rows
        self.cells = cells
        self.cursorColumn = cursorColumn
        self.cursorRow = cursorRow
        self.cursorVisible = cursorVisible
        self.revision = revision
    }

    public func cell(column: Int, row: Int) -> TerminalCell {
        guard column >= 0, column < columns, row >= 0, row < rows else {
            return TerminalCell()
        }
        return cells[(row * columns) + column]
    }
}

public struct TerminalGrid {
    public private(set) var columns: Int
    public private(set) var rows: Int
    public private(set) var cursorColumn: Int = 0
    public private(set) var cursorRow: Int = 0
    public private(set) var cursorVisible: Bool = true

    private var cells: [TerminalCell]
    private var savedCursor = (column: 0, row: 0)
    private var style = TerminalCellStyle()
    private var scrollTop = 0
    private var scrollBottom: Int
    private var pendingWrap = false
    private var revision: UInt64 = 0
    private var mainCells: [TerminalCell]?
    private var mainCursor: (column: Int, row: Int)?

    public init(columns: Int, rows: Int) {
        self.columns = max(columns, 1)
        self.rows = max(rows, 1)
        self.cells = Array(repeating: TerminalCell(), count: max(columns, 1) * max(rows, 1))
        self.scrollBottom = max(rows, 1) - 1
    }

    public mutating func resize(columns: Int, rows: Int) {
        let newColumns = max(columns, 1)
        let newRows = max(rows, 1)
        var newCells = Array(repeating: TerminalCell(style: style), count: newColumns * newRows)
        let copyRows = min(self.rows, newRows)
        let copyColumns = min(self.columns, newColumns)
        for row in 0..<copyRows {
            for column in 0..<copyColumns {
                newCells[(row * newColumns) + column] = cells[(row * self.columns) + column]
            }
        }
        self.columns = newColumns
        self.rows = newRows
        self.cells = newCells
        cursorColumn = min(cursorColumn, newColumns - 1)
        cursorRow = min(cursorRow, newRows - 1)
        scrollTop = 0
        scrollBottom = newRows - 1
        pendingWrap = false
        markDirty()
    }

    public mutating func put(_ text: String) {
        guard !text.isEmpty else { return }
        let width = terminalCharacterWidth(text)
        if width == 0 {
            if cursorColumn > 0 {
                let index = index(column: cursorColumn - 1, row: cursorRow)
                cells[index].text += text
                markDirty()
            }
            return
        }
        if pendingWrap {
            lineFeed()
            cursorColumn = 0
            pendingWrap = false
        }

        if width == 2 && cursorColumn == columns - 1 {
            lineFeed()
            cursorColumn = 0
        }
        cells[index(column: cursorColumn, row: cursorRow)] = TerminalCell(text: text, style: style, width: width)
        if width == 2 && cursorColumn + 1 < columns {
            cells[index(column: cursorColumn + 1, row: cursorRow)] = TerminalCell(text: "", style: style, width: 0)
        }
        if cursorColumn + width >= columns {
            cursorColumn = columns - 1
            pendingWrap = true
        } else {
            cursorColumn += width
        }
        markDirty()
    }

    public mutating func carriageReturn() {
        cursorColumn = 0
        pendingWrap = false
        markDirty()
    }

    public mutating func lineFeed() {
        pendingWrap = false
        if cursorRow == scrollBottom {
            scrollUp()
        } else {
            cursorRow = min(cursorRow + 1, rows - 1)
        }
        markDirty()
    }

    public mutating func backspace() {
        cursorColumn = max(cursorColumn - 1, 0)
        pendingWrap = false
        markDirty()
    }

    public mutating func tab() {
        let next = min(((cursorColumn / 8) + 1) * 8, columns - 1)
        cursorColumn = max(next, 0)
        pendingWrap = false
        markDirty()
    }

    public mutating func moveCursor(column: Int? = nil, row: Int? = nil) {
        if let column { cursorColumn = min(max(column, 0), columns - 1) }
        if let row { cursorRow = min(max(row, scrollTop), scrollBottom) }
        pendingWrap = false
        markDirty()
    }

    public mutating func saveCursor() { savedCursor = (cursorColumn, cursorRow) }
    public mutating func restoreCursor() { moveCursor(column: savedCursor.column, row: savedCursor.row) }
    public mutating func setCursorVisible(_ visible: Bool) {
        cursorVisible = visible
        markDirty()
    }

    public mutating func setStyle(_ style: TerminalCellStyle) { self.style = style }

    public mutating func eraseDisplay(mode: Int) {
        switch mode {
        case 0:
            eraseCells(from: index(column: cursorColumn, row: cursorRow), to: cells.count - 1)
        case 1:
            eraseCells(from: 0, to: index(column: cursorColumn, row: cursorRow))
        default:
            cells = Array(repeating: TerminalCell(style: style), count: columns * rows)
        }
        pendingWrap = false
        markDirty()
    }

    public mutating func eraseLine(mode: Int) {
        switch mode {
        case 0:
            eraseCells(from: index(column: cursorColumn, row: cursorRow), to: index(column: columns - 1, row: cursorRow))
        case 1:
            eraseCells(from: index(column: 0, row: cursorRow), to: index(column: cursorColumn, row: cursorRow))
        default:
            eraseCells(from: index(column: 0, row: cursorRow), to: index(column: columns - 1, row: cursorRow))
        }
        pendingWrap = false
        markDirty()
    }

    public mutating func setScrollRegion(top: Int, bottom: Int) {
        scrollTop = min(max(top, 0), rows - 1)
        scrollBottom = min(max(bottom, scrollTop), rows - 1)
        cursorColumn = 0
        cursorRow = scrollTop
        pendingWrap = false
        markDirty()
    }

    public mutating func reset() {
        style = TerminalCellStyle()
        cells = Array(repeating: TerminalCell(), count: columns * rows)
        cursorColumn = 0
        cursorRow = 0
        cursorVisible = true
        scrollTop = 0
        scrollBottom = rows - 1
        pendingWrap = false
        markDirty()
    }

    public mutating func enterAlternateScreen() {
        guard mainCells == nil else { return }
        mainCells = cells
        mainCursor = (cursorColumn, cursorRow)
        cells = Array(repeating: TerminalCell(), count: columns * rows)
        cursorColumn = 0
        cursorRow = 0
        pendingWrap = false
        markDirty()
    }

    public mutating func leaveAlternateScreen() {
        guard let mainCells else { return }
        cells = mainCells
        cursorColumn = mainCursor?.column ?? 0
        cursorRow = mainCursor?.row ?? 0
        pendingWrap = false
        self.mainCells = nil
        mainCursor = nil
        markDirty()
    }

    public func snapshot() -> TerminalGridSnapshot {
        TerminalGridSnapshot(
            columns: columns,
            rows: rows,
            cells: cells,
            cursorColumn: cursorColumn,
            cursorRow: cursorRow,
            cursorVisible: cursorVisible,
            revision: revision
        )
    }

    private func index(column: Int, row: Int) -> Int { (row * columns) + column }

    private mutating func markDirty() {
        revision &+= 1
    }

    private mutating func eraseCells(from start: Int, to end: Int) {
        guard !cells.isEmpty else { return }
        let lower = min(max(start, 0), cells.count - 1)
        let upper = min(max(end, lower), cells.count - 1)
        for index in lower...upper {
            cells[index] = TerminalCell(style: style)
        }
    }

    private mutating func scrollUp() {
        guard scrollTop <= scrollBottom else { return }
        let first = scrollTop * columns
        let last = (scrollBottom + 1) * columns
        if last <= cells.count {
            cells.removeSubrange(first..<(first + columns))
            cells.insert(contentsOf: Array(repeating: TerminalCell(style: style), count: columns), at: last - columns)
        }
    }
}

public func terminalCharacterWidth(_ text: String) -> Int {
    guard let scalar = text.unicodeScalars.first else { return 0 }
    let value = scalar.value
    if scalar.properties.generalCategory == .nonspacingMark ||
        scalar.properties.generalCategory == .spacingMark ||
        scalar.properties.generalCategory == .enclosingMark {
        return 0
    }
    if value < 0x20 || (value >= 0x7F && value <= 0x9F) { return 0 }
    if (0x1100...0x115F).contains(value) ||
        (0x2E80...0xA4CF).contains(value) ||
        (0xAC00...0xD7A3).contains(value) ||
        (0xF900...0xFAFF).contains(value) ||
        (0xFE10...0xFE19).contains(value) ||
        (0xFE30...0xFE6F).contains(value) ||
        (0xFF00...0xFF60).contains(value) ||
        (0x1F300...0x1FAFF).contains(value) {
        return 2
    }
    return 1
}
