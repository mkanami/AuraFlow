import Foundation

public enum TerminalWallpaperCanvas {
    /// Nyancat paints pairs of columns and reserves the last terminal row.
    /// Continue its opaque canvas through those untouched cells and fractional
    /// raster margins, instead of exposing the user's default black background.
    /// Apply this only while rendering; the PTY and saved appearance stay intact.
    public static func renderConfiguration(
        command: TerminalCommandConfiguration,
        render: TerminalRenderConfiguration,
        snapshot: TerminalGridSnapshot
    ) -> TerminalRenderConfiguration {
        guard URL(fileURLWithPath: command.executable).lastPathComponent == "nyancat" else { return render }
        guard snapshot.columns > 1, snapshot.rows > 1 else { return render }
        func untouched(_ cell: TerminalCell) -> Bool {
            cell.text == " " && cell.style.background == .default && cell.style.attributes.isEmpty
        }
        let lastRow = (0..<snapshot.columns).allSatisfy {
            untouched(snapshot.cell(column: $0, row: snapshot.rows - 1))
        } ? snapshot.rows - 2 : snapshot.rows - 1
        let lastColumn = (0...lastRow).allSatisfy {
            untouched(snapshot.cell(column: snapshot.columns - 1, row: $0))
        } ? snapshot.columns - 2 : snapshot.columns - 1
        var colors: [(color: TerminalColor, count: Int)] = []
        let perimeter = (0...lastColumn).flatMap {
            [snapshot.cell(column: $0, row: 0), snapshot.cell(column: $0, row: lastRow)]
        } + (1..<max(lastRow, 1)).flatMap {
            [snapshot.cell(column: 0, row: $0), snapshot.cell(column: lastColumn, row: $0)]
        }
        for cell in perimeter where cell.text == " " && cell.style.background != .default
            && !cell.style.attributes.contains(.inverse) {
            if let index = colors.firstIndex(where: { $0.color == cell.style.background }) {
                colors[index].count += 1
            } else {
                colors.append((cell.style.background, 1))
            }
        }
        guard let canvas = colors.max(by: { $0.count < $1.count })?.color else { return render }
        var result = render
        result.background = canvas.resolved(defaultColor: render.background, palette: TerminalPalette.kittyDefault16)
        result.backgroundOpacity = 1
        return result
    }
}
