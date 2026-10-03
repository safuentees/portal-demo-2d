import simd

/// An object's name stays the same when the scene array is reordered.
enum SceneObjectID: Hashable {
    case bottomBar
    case topBar
    case circle
    case cone
    case circleClone
    case coneClone
    case custom(String)
}

/// Initial scene data. Matching geometry parameters share a GPU mesh.
struct SceneObjectConfiguration {
    enum Geometry: Hashable {
        case square
        case circle
        case triangle
        /// Full opening angle in radians and forward length before placement scaling.
        case cone(fieldOfView: Float, length: Float = 1)
    }

    let id: SceneObjectID
    let geometry: Geometry
    var placement = ObjectPlacement()
    var color = SIMD4<Float>(1, 1, 1, 1)
    /// Extend this vision triangle past the visible window while keeping its angle.
    var extendsVisionToViewport = false
}
