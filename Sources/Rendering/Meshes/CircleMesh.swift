import MetalKit

enum CircleMesh {
    static let localRadius: Float = 1

    /// Radius of a circle enclosing the scaled mesh. Unequal x/y scales use the larger radius.
    /// Rotation cannot change this bound; z only controls depth in the flat scene.
    static func boundingRadius(for scale: SIMD3<Float>) -> Float {
        localRadius * max(abs(scale.x), abs(scale.y))
    }

    enum SetupError: LocalizedError {
        case invalidSegmentCount

        var errorDescription: String? {
            "A circle needs between 3 and 65,535 segments for UInt16 indices."
        }
    }

    /// A filled circle of radius 1. ObjectPlacement controls its displayed size.
    static func make(
        device: MTLDevice,
        segments: Int = SceneConfiguration.circleSegments
    ) throws -> MTKMesh {
        guard (3...Int(UInt16.max)).contains(segments) else {
            throw SetupError.invalidSegmentCount
        }
        // Vertex 0 is the center; the remaining vertices trace the rim once.
        var positions: [SIMD2<Float>] = [.zero]
        positions.reserveCapacity(segments + 1)
        for index in 0..<segments {
            let angle = 2 * Float.pi * Float(index) / Float(segments)
            positions.append(SIMD2(cos(angle), sin(angle)) * localRadius)
        }

        // Each triangle joins the center to two adjacent rim vertices.
        // The final triangle wraps back to vertex 1, closing the circle.
        var indices: [UInt16] = []
        indices.reserveCapacity(segments * 3)
        for index in 1...segments {
            let next = index == segments ? 1 : index + 1
            indices.append(contentsOf: [0, UInt16(index), UInt16(next)])
        }
        
        return try Mesh2D.make(
            device: device,
            positions: positions,
            indices: indices,
            geometryType: .triangles
        )
    }
}
