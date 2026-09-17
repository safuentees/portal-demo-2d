import simd

/// Keep this layout identical to ShaderUniforms in Shaders.metal.
/// 376 bytes of fields, padded to a 384-byte stride with 16-byte alignment.
struct ShaderUniforms {
    var modelMatrix: simd_float4x4
    var viewMatrix: simd_float4x4
    var canvasMatrix: simd_float4x4
    var color: SIMD4<Float>
    var worldToPortal = matrix_identity_float4x4
    var eyeInPortal = SIMD4<Float>.zero
    var worldToClonePortal = matrix_identity_float4x4
    var eyeInClonePortal = SIMD4<Float>.zero
    /// Full drawable width and height in pixels, including Retina scaling.
    var resolution = SIMD2<Float>(repeating: 1)
}
