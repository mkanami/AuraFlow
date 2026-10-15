import AuraTerminalWallpaperCore
import Foundation
import Testing

@Test func nyancatCanvasContinuesItsPaintedBackgroundWithoutChangingCellsOrSettings() {
    let blue = TerminalColor.rgb(3, 8, 99)
    let pink = TerminalColor.rgb(220, 100, 170)
    var cells = Array(repeating: TerminalCell(), count: 15 * 8)
    for row in 0..<7 {
        for column in 0..<14 {
            // Make the interior a different color to ensure we sample the
            // animation's perimeter, not the largest object in the picture.
            cells[row * 15 + column].style.background = row == 0 || row == 6 || column == 0 || column == 13 ? blue : pink
        }
    }
    let snapshot = TerminalGridSnapshot(columns: 15, rows: 8, cells: cells,
        cursorColumn: 0, cursorRow: 0, cursorVisible: false, revision: 12)
    let render = TerminalRenderConfiguration(background: .black, backgroundOpacity: 0.4)
    let command = TerminalCommandConfiguration(executable: "/opt/homebrew/bin/nyancat", arguments: ["-n", "-s"])
    let canvas = TerminalWallpaperCanvas.renderConfiguration(command: command, render: render, snapshot: snapshot)
    var expected = render
    expected.background = blue.resolved(defaultColor: .black, palette: TerminalPalette.kittyDefault16)
    expected.backgroundOpacity = 1
    #expect(canvas == expected)
    #expect(render.background == .black && render.backgroundOpacity == 0.4)
    #expect(snapshot.cells == cells && snapshot.revision == 12)
    #expect(snapshot.cell(column: 14, row: 7).style.background == .default)
    let other = TerminalWallpaperCanvas.renderConfiguration(command: .init(executable: "pipes.sh"), render: render, snapshot: snapshot)
    #expect(other == render)
}

@Test func nyancatHelpOrEmptyOutputPreservesTheConfiguredBackground() {
    var parser = VTParser(columns: 80, rows: 24)
    let render = TerminalRenderConfiguration(background: .init(red: 0.2, green: 0.3, blue: 0.4), backgroundOpacity: 0.7)
    let command = TerminalCommandConfiguration(executable: "nyancat", arguments: ["--help"])
    #expect(TerminalWallpaperCanvas.renderConfiguration(command: command, render: render, snapshot: parser.grid.snapshot()) == render)
    parser.feed(Data("usage: nyancat [-hitn]".utf8))
    #expect(TerminalWallpaperCanvas.renderConfiguration(command: command, render: render, snapshot: parser.grid.snapshot()) == render)
}
