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
    float4x4 worldToClonePortal;
    float4 eyeInClonePortal;
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

// Both points must be in the same portal-local coordinate system.
// The opening lies at y = 0, from -portalHalfWidth to +portalHalfWidth.
// A crossing must lie strictly between the segment's endpoints.
inline bool intersectsPortal(float2 start, float2 end, float portalHalfWidth) {
    float dy = end.y - start.y;
    if (abs(dy) < 0.000001)
        return false;

    float t = -start.y / dy;
    if (t <= 0.0 || t >= 1.0)
        return false;

    float x = start.x + t * (end.x - start.x);
    return abs(x) <= portalHalfWidth;
}

fragment float4 portal_fragment(
    VertexOut input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(1)]]
) {
    float2 portalPosition = (
        float4(input.worldPosition, 0.0, 1.0) * uniforms.worldToPortal
    ).xy;

    // Remove original vision that continues through the entrance opening.
    if (intersectsPortal(uniforms.eyeInPortal.xy, portalPosition, 0.2))
        discard_fragment();

    return uniforms.color;
}


fragment float4 portal_clone_fragment(
    VertexOut input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(1)]]
) {
    float2 portalPosition = (
        float4(input.worldPosition, 0.0, 1.0) * uniforms.worldToClonePortal
    ).xy;

    // Show only cloned vision that continues through the exit opening.
    if (!intersectsPortal(uniforms.eyeInClonePortal.xy, portalPosition, 0.2))
        discard_fragment();

    return uniforms.color;
}
