import MetalKit

enum SquareMesh {
    static func make(device: MTLDevice) throws -> MTKMesh {
        let positions: [SIMD2<Float>] = [
            SIMD2(-0.5, -0.5),
            SIMD2( 0.5, -0.5),
            SIMD2( 0.5,  0.5),
            SIMD2(-0.5,  0.5)
        ]
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]

        return try Mesh2D.make(
            device: device,
            positions: positions,
            indices: indices,
            geometryType: .triangles
        )
    }
}
