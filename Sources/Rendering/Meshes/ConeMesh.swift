import MetalKit

/// A flat vision cone, pointing along +Y with its tip at the origin.
enum ConeMesh {
    enum SetupError: LocalizedError {
        case invalidFieldOfView
        case invalidLength
        case invalidDimensions

        var errorDescription: String? {
            switch self {
            case .invalidFieldOfView:
                return "Cone field of view must be finite and between 0 and pi radians, excluding both endpoints."
            case .invalidLength:
                return "Cone length must be finite and greater than zero."
            case .invalidDimensions:
                return "Cone parameters must produce a finite, positive width."
            }
        }
    }

    /// Full width and forward length in local canvas units, before placement scaling.
    static func dimensions(fieldOfView: Float, length: Float) throws -> SIMD2<Float> {
        guard fieldOfView.isFinite, fieldOfView > 0, fieldOfView < .pi else {
            throw SetupError.invalidFieldOfView
        }
        guard length.isFinite, length > 0 else {
            throw SetupError.invalidLength
        }
        let halfWidth = length * tan(fieldOfView / 2)
        let width = 2 * halfWidth
        guard halfWidth > 0, width.isFinite else {
            throw SetupError.invalidDimensions
        }
        return SIMD2(width, length)
    }

    /// Field of view is the full opening angle in radians; length reaches the flat far edge.
    static func make(
        device: MTLDevice,
        fieldOfView: Float,
        length: Float = 1
    ) throws -> MTKMesh {
        let size = try dimensions(fieldOfView: fieldOfView, length: length)
        let halfWidth = size.x / 2
        return try Mesh2D.make(
            device: device,
            positions: [.zero, SIMD2(-halfWidth, size.y), SIMD2(halfWidth, size.y)],
            indices: [0, 1, 2],
            geometryType: .triangles
        )
    }
}
