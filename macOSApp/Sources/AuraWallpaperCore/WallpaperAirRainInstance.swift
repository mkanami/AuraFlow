import simd

/// One completed falling-rain state, shared by the layer and glass compositor.
/// Pane coordinates have height 1080 and a top-left origin.
struct WallpaperAirRainInstance {
    var ellipse: SIMD4<Float> // center x/y, half width/length, including soft edge
    var color: SIMD4<Float>   // unassociated RGB and opacity
    var optics: SIMD4<Float> // rotation, visible width / quad width, visible length / quad length, soft halo
}
