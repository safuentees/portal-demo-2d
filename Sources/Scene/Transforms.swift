import simd

/// Matches metsl: row vectors, +Z forward, and Metal depth in the 0...1 range.
/// Shaders multiply position * model * view * projection.
enum Transforms {
    static func translation(_ offset: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, offset.x),
            SIMD4<Float>(0, 1, 0, offset.y),
            SIMD4<Float>(0, 0, 1, offset.z),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    static func perspective(
        aspect: Float,
        fieldOfView: Float,
        near: Float,
        far: Float
    ) -> simd_float4x4 {
        let yScale = 1 / tan(fieldOfView / 2)
        let zScale = far / (far - near)
        return simd_float4x4(columns: (
            SIMD4<Float>(yScale / aspect, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, zScale, -near * zScale),
            SIMD4<Float>(0, 0, 1, 0)
        ))
    }
}
