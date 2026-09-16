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

    // Solid circles have radius 1 before placement scaling.
    static let circleSegments = 64
    static let circleScale: Float = 0.1

    // One entry per object. Give each entry a unique ID to access it later.
    // At rest, x/y range from -1 to 1 across the centered square canvas.
    // A square at scale 1 spans half the canvas; a circle spans the whole canvas.
    // Use z = 0 and scale.z = 1 for this flat layout.
    static let objects: [SceneObjectConfiguration] = [
        SceneObjectConfiguration(
            id: .bottomBar,
            geometry: .square,
            placement: ObjectPlacement(
                position: SIMD3(0.9 - (0.4 / 2), -0.9, 0),
                scale: SIMD3(0.4, 0.05, 1)
            ),
            color: objectColor
        ),
        SceneObjectConfiguration(
            id: .topBar,
            geometry: .square,
            placement: ObjectPlacement(
                position: SIMD3(-0.9 + (0.4 / 2), 0.9, 0),
                scale: SIMD3(0.4, 0.05, 1)
            ),
            color: objectColor
        ),
        SceneObjectConfiguration(
            id: .circle,
            geometry: .circle,
            placement: ObjectPlacement(
                position: SIMD3(0, 0, 0),
                scale: SIMD3(circleScale, circleScale, 1)
            ),
            color: objectColor
        ),
    ]

    // Geometry settings for the optional sphere mesh.
    static let sphereExtent = SIMD3<Float>(repeating: 0.75)
    static let sphereSegments = SIMD2<UInt32>(30, 30)

    static let cameraSpeed: Float = 1.5
}
