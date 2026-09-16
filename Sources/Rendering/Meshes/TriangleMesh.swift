import MetalKit

enum TriangleMesh {
    /// Flip once around the bounds center, keeping the triangle in the same local footprint.
    /// The resulting tip is at the origin and the flat edge faces +Y.
    static func make(device: MTLDevice) throws -> MTKMesh {
        let originalPositions: [SIMD2<Float>] = [
            SIMD2( 0, 1),
            SIMD2( 0.5, 0),
            SIMD2( -0.5, 0),
        ]

        let center = SIMD2<Float>(0, 0.5)
        // A half-turn around this center is center + -(point - center).
        let positions = originalPositions.map { center - ($0 - center) }

        let indices: [UInt16] = [0, 1, 2]

        return try Mesh2D.make(
            device: device,
            positions: positions,
            indices: indices,
            geometryType: .triangles
        )
    }
}
