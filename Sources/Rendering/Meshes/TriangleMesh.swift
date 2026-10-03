import MetalKit

enum TriangleMesh {
    /// A unit triangle with its tip at the origin and its flat edge facing +Y.
    static func make(device: MTLDevice) throws -> MTKMesh {
        let positions: [SIMD2<Float>] = [
            SIMD2(0, 0),
            SIMD2(-0.5, 1),
            SIMD2(0.5, 1),
        ]

        let indices: [UInt16] = [0, 1, 2]

        return try Mesh2D.make(
            device: device,
            positions: positions,
            indices: indices,
            geometryType: .triangles
        )
    }
}
