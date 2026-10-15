import simd

struct TerminalMetalVertex: Equatable {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
}

enum TerminalTextureOrientation {
    // Metal texture coordinates use (0, 0) for the top-left texel. Match that
    // to the top of the desktop quad; mapping it to the lower vertices flips
    // the terminal's rows vertically on screen.
    static let fullScreenQuad = [
        TerminalMetalVertex(position: SIMD2(-1, -1), uv: SIMD2(0, 1)),
        TerminalMetalVertex(position: SIMD2(1, -1), uv: SIMD2(1, 1)),
        TerminalMetalVertex(position: SIMD2(-1, 1), uv: SIMD2(0, 0)),
        TerminalMetalVertex(position: SIMD2(1, 1), uv: SIMD2(1, 0)),
    ]
}
