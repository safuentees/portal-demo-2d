#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
};

struct VertexOut {
    float4 position [[position]];
};

// Match the field order and types in Rendering/ShaderUniforms.swift.
struct ShaderUniforms {
    float4x4 modelMatrix;
    float4x4 viewMatrix;
    float4x4 canvasMatrix;
    float4 color;
    float4x4 worldToPortal;
    float4 eyeInPortal;
    float2 resolution;
};

vertex VertexOut object_vertex(
    VertexIn input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(1)]]
) {
    VertexOut out;
    // Fit the flat square canvas into the padded window using x/y scaling only.
    // No perspective: depth never changes an object's apparent size.
    out.position = float4(input.position, 0.0, 1.0)
        * uniforms.modelMatrix
        * uniforms.viewMatrix
        * uniforms.canvasMatrix;
    return out;
}

fragment float4 object_fragment(constant ShaderUniforms &uniforms [[buffer(1)]]) {
    return uniforms.color;
}

fragment float4 portal_fragment(
    VertexOut input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(1)]]
) {
    float2 pixelPosition = input.position.xy;

    // pixelPosition / uniforms.resolution gives 0...1 coordinates across the drawable.
    // Replace this with your clipping logic later.
    return uniforms.color;
}
