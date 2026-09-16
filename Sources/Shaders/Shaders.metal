#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float3 position [[attribute(0)]];
};

struct VertexOut {
    float4 position [[position]];
};

// Match the field order and types in Rendering/ShaderUniforms.swift.
struct ShaderUniforms {
    float4x4 modelMatrix;
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float4 color;
};

vertex VertexOut sphere_vertex(
    VertexIn input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(1)]]
) {
    VertexOut out;
    // Same row-vector convention as metsl. The camera looks along +Z.
    out.position = float4(input.position, 1.0)
        * uniforms.modelMatrix
        * uniforms.viewMatrix
        * uniforms.projectionMatrix;
    return out;
}

fragment float4 sphere_fragment(constant ShaderUniforms &uniforms [[buffer(1)]]) {
    return uniforms.color;
}
