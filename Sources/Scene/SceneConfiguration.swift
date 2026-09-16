import Metal
import simd

/// Start here when changing the scene. RGBA components use the 0...1 range.
enum SceneConfiguration {
    static let sphereColor = SIMD4<Float>(0.20, 0.45, 0.90, 1.0)
    static let backgroundColor = MTLClearColor(red: 1, green: 1, blue: 0.8, alpha: 1)

    static let sphereExtent = SIMD3<Float>(repeating: 0.75)
    static let sphereSegments = SIMD2<UInt32>(30, 30)
    static let spherePosition = SIMD3<Float>(0, 0, 2.5)

    static let fieldOfViewRadians: Float = 70 * .pi / 180
    static let nearPlane: Float = 0.1
    static let farPlane: Float = 100
    static let cameraSpeed: Float = 1.5
}
