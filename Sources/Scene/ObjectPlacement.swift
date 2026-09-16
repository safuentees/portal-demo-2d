import simd

/// An object's position, size, and rotation, independent of its mesh.
struct ObjectPlacement {
    var position: SIMD3<Float> = .zero
    var scale = SIMD3<Float>(repeating: 1)
    /// Rotation in radians around the mesh's local origin; positive is counterclockwise.
    var angle: Float = 0

    var modelMatrix: simd_float4x4 {
        // Row vectors: scale, rotate around the mesh origin, then move into place.
        Transforms.scaling(scale) * Transforms.rotation(angle) * Transforms.translation(position)
    }
}
