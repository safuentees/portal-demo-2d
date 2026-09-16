import simd

/// An object's name stays the same when the scene array is reordered.
enum SceneObjectID: Hashable {
    case bottomBar
    case topBar
    case circle
    case custom(String)
}

/// Initial scene data. The renderer supplies the shared GPU mesh for each geometry.
struct SceneObjectConfiguration {
    enum Geometry {
        case square
        case circle
    }

    let id: SceneObjectID
    let geometry: Geometry
    var placement = ObjectPlacement()
    var color = SIMD4<Float>(1, 1, 1, 1)
}
