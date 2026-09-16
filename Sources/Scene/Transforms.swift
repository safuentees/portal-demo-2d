import simd

/// Matches metsl: row vectors, +Z forward, and Metal depth in the 0...1 range.
/// The flat scene uses position * model * view * canvas, with no perspective.
enum Transforms {
    static func scaling(_ scale: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4<Float>(scale.x, scale.y, scale.z, 1))
    }

    /// Rotate counterclockwise in the XY plane. The angle is in radians.
    static func rotation(_ angle: Float) -> simd_float4x4 {
        let cosine = cos(angle)
        let sine = sin(angle)
        return simd_float4x4(columns: (
            SIMD4<Float>(cosine, -sine, 0, 0),
            SIMD4<Float>(sine, cosine, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    /// Fit the logical -1...1 square inside a padded view, centered on the origin.
    /// Size and padding share the same units (points for the onscreen view).
    static func squareCanvas(size: SIMD2<Float>, padding: Float) -> simd_float4x4 {
        guard size.x > 0, size.y > 0 else {
            return scaling(SIMD3(0, 0, 1))
        }
        let side = canvasSide(size: size, padding: padding)
        // Only x/y change. Depth and w stay unchanged, so there is no perspective.
        return scaling(SIMD3(side / size.x, side / size.y, 1))
    }

    /// Convert bottom-left-relative view points to the same coordinates used by objects.
    /// Padding is still usable space, so values outside -1...1 are preserved.
    static func canvasPosition(
        from viewPosition: SIMD2<Float>, size: SIMD2<Float>, padding: Float
    ) -> SIMD2<Float>? {
        guard size.x > 0, size.y > 0 else { return nil }
        let side = canvasSide(size: size, padding: padding)
        guard side > 0 else { return nil }
        return (viewPosition - size / 2) * (2 / side)
    }

    private static func canvasSide(size: SIMD2<Float>, padding: Float) -> Float {
        max(min(size.x, size.y) - 2 * max(padding, 0), 0)
    }

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
