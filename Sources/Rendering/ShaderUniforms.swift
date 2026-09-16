import simd

/// Keep this layout identical to ShaderUniforms in Shaders.metal.
/// Three 64-byte matrices and one 16-byte color = 208 bytes, all 16-byte aligned.
struct ShaderUniforms {
    var modelMatrix: simd_float4x4
    var viewMatrix: simd_float4x4
    var canvasMatrix: simd_float4x4
    var color: SIMD4<Float>
    var worldToPortal = matrix_identity_float4x4
    var eyeInPortal = SIMD4<Float>.zero
}
