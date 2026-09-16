import Metal
import simd

/// Start here when changing the scene layout and appearance.
enum SceneConfiguration {
    // Colors use RGBA components in the 0...1 range.
    static let backgroundColor = MTLClearColor(red: 24.0 / 255.0, green: 24.0 / 255.0, blue: 27.0 / 255.0, alpha: 1)
    static let objectColor = SIMD4<Float>(147.0 / 255.0, 197.0 / 255.0, 253.0 / 255.0, 1.0)
    static let playerColor = SIMD4<Float>(219.0 / 255.0, 234.0 / 255.0, 254.0 / 255.0, 1.0)
    static let visionColor = SIMD4<Float>(147.0 / 255.0, 197.0 / 255.0, 253.0 / 255.0, 0.18)

    // Window/layout dimensions use macOS points, so padding looks consistent on Retina.
    static let canvasPadding: CGFloat = 100
    static let initialCanvasSide: CGFloat = 700
    static let minimumCanvasSide: CGFloat = 400

    // Solid circles have radius 1 before placement scaling.
    static let circleSegments = 64
    static let circleScale: Float = 0.05
    static let visionScale = SIMD3<Float>(0.62, 0.50, 1)

    // Show the cloned pair beside the originals until portal mapping is added.
    static let cloneOffset = SIMD3<Float>(0.65, 0, 0)

    // Ignore aiming too close to the player, where tiny pointer changes cause large turns.
    static let lookDeadZoneRadius: Float = 0.07

    // Canvas units per second for WASD movement of the cone and circle together.
    static let objectMovementSpeed: Float = 0.85

    // One entry per object. Give each entry a unique ID to access it later.
    // At rest, x/y range from -1 to 1 across the centered square canvas.
    // A square at scale 1 spans half the canvas; a circle spans the whole canvas.
    // Depth separates visual layers without perspective; scale.z stays at 1.
    static let objects: [SceneObjectConfiguration] = [
        SceneObjectConfiguration(
            id: .bottomBar,
            geometry: .square,
            placement: ObjectPlacement(
                position: SIMD3(0.5 - (0.4 / 2), -0.9, 0),
                scale: SIMD3(0.4, 0.035, 1)
            ),
            color: objectColor
        ),
        SceneObjectConfiguration(
            id: .topBar,
            geometry: .square,
            placement: ObjectPlacement(
                position: SIMD3(-0.9 + (0.4 / 2), 0.9, 0),
                scale: SIMD3(0.4, 0.035, 1),
                angle: .pi
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
            color: playerColor
        ),
        SceneObjectConfiguration(
            id: .cone,
            geometry: .triangle,
            placement: ObjectPlacement(
                // Depth only controls layering: the translucent field sits behind solid markers.
                position: SIMD3(0, 0, 0.5),
                scale: visionScale
            ),
            color: visionColor
        ),
    ]

    // Geometry settings for the optional sphere mesh.
    static let sphereExtent = SIMD3<Float>(repeating: 0.75)
    static let sphereSegments = SIMD2<UInt32>(30, 30)

    static let cameraSpeed: Float = 1.5
}
