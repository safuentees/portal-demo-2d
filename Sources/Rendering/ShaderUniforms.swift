import simd

/// Keep this layout identical to ShaderUniforms in Shaders.metal.
/// 400-byte stride with 16-byte alignment.
struct ShaderUniforms {
    var modelMatrix: simd_float4x4
    var viewMatrix: simd_float4x4
    var canvasMatrix: simd_float4x4
    var color: SIMD4<Float>
    var worldToEntrance = matrix_identity_float4x4
    var eyeInEntrance = SIMD4<Float>.zero
    var worldToExit = matrix_identity_float4x4
    var eyeInExit = SIMD4<Float>.zero
    /// Full drawable width and height in pixels, including Retina scaling.
    var resolution = SIMD2<Float>(repeating: 1)
    /// x = entrance, y = exit; zero disables a missing or closed opening.
    var portalHalfWidths = SIMD2<Float>.zero
    /// Edge fade in drawable pixels; zero keeps the original hard visibility test.
    var visionFeatherPixels: Float = 0
}
