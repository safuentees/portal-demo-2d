import Metal
import simd

/// Start here when changing the scene layout and appearance.
enum SceneConfiguration {
    // Colors use RGBA components in the 0...1 range.
    static let backgroundColor = MTLClearColor(red: 24.0 / 255.0, green: 24.0 / 255.0, blue: 27.0 / 255.0, alpha: 1)
    static let objectColor = SIMD4<Float>(147.0 / 255.0, 197.0 / 255.0, 253.0 / 255.0, 1.0)

    // Window/layout dimensions use macOS points, so padding looks consistent on Retina.
    static let canvasPadding: CGFloat = 100
    static let initialCanvasSide: CGFloat = 700
    static let minimumCanvasSide: CGFloat = 400

    // One entry per square. Add, remove, or edit entries here.
    // At rest, x/y range from -1 to 1 across the centered square canvas.
    // Scale 1 keeps the unit mesh size: half the canvas width/height.
    // Use z = 0 and scale.z = 1 for these flat squares.
    static let squares: [ObjectPlacement] = [
        // Bottom-right bar.
        ObjectPlacement(
            position: SIMD3(0.9 - (0.4 / 2), -0.9, 0),
            scale: SIMD3(0.4, 0.05, 1)
        ),
        // Top-left bar.
        ObjectPlacement(
            position: SIMD3(-0.9 + (0.4 / 2), 0.9, 0),
            scale: SIMD3(0.4, 0.05, 1)
        ),
    ]
    // Solid circle: radius 1 before placement scaling. More segments make a smoother edge.
    static let circleSegments = 64
    static let scale: Float = 0.1
    static let circlePlacement = ObjectPlacement(
        position: SIMD3(0, 0, 0),
        scale: SIMD3(scale, scale, 1)
    )

    // Geometry settings for the optional sphere mesh.
    static let sphereExtent = SIMD3<Float>(repeating: 0.75)
    static let sphereSegments = SIMD2<UInt32>(30, 30)

    static let cameraSpeed: Float = 1.5
}
