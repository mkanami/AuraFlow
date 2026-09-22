@testable import AuraTerminalWallpaperAgent
import Testing

@Test func terminalTextureKeepsTopAndBottomRowsUpright() {
    let topLeft = TerminalTextureOrientation.fullScreenQuad.first {
        $0.position == SIMD2<Float>(-1, 1)
    }
    let bottomLeft = TerminalTextureOrientation.fullScreenQuad.first {
        $0.position == SIMD2<Float>(-1, -1)
    }

    // A marker in terminal row zero must sample the top of the texture and
    // one in the last row must sample the bottom.
    #expect(topLeft?.uv == SIMD2<Float>(0, 0))
    #expect(bottomLeft?.uv == SIMD2<Float>(0, 1))
}
