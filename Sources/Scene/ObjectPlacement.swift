import simd

/// An object's position and size, independent of its mesh.
struct ObjectPlacement {
    var position: SIMD3<Float> = .zero
    var scale = SIMD3<Float>(repeating: 1)

    var modelMatrix: simd_float4x4 {
        // Row vectors: resize around the mesh origin, then move into place.
        Transforms.scaling(scale) * Transforms.translation(position)
    }
}
