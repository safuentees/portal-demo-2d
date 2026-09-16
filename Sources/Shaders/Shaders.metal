#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 worldPosition;
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
    
    float4 world = float4(input.position, 0.0, 1.0)
        * uniforms.modelMatrix;

    out.worldPosition = world.xy;
    
    return out;
}

fragment float4 object_fragment(constant ShaderUniforms &uniforms [[buffer(1)]]) {
    return uniforms.color;
}

fragment float4 portal_fragment(
    VertexOut input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(1)]]
) {
    float2 portalPosition = (
            float4(input.worldPosition, 0.0, 1.0)
            * uniforms.worldToPortal
        ).xy;
    
    float portalHalfWidth = 0.2;

    float2 A = uniforms.eyeInPortal.xy;
    float2 B = portalPosition;

    float dy = B.y - A.y;

    // Avoid division by zero for a parallel segment.
    if (abs(dy) < 0.000001)
        discard_fragment();

    float t = -A.y / dy;
    float x = A.x + t * (B.x - A.x);

    // Keep only pixels whose sightline crosses the portal opening.
    if (t >= 1.0 or t <= 0 or abs(x) > portalHalfWidth)
        discard_fragment();

    return uniforms.color;
}
