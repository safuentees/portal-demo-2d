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
    float4x4 worldToEntrance;
    float4 eyeInEntrance;
    float4x4 worldToExit;
    float4 eyeInExit;
    float2 resolution;
    float2 portalHalfWidths;
};

vertex VertexOut object_vertex(
    VertexIn input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(1)]]
) {
    VertexOut out;
    // Fit the flat square canvas into the padded window using x/y scaling only.
    // No perspective: depth never changes an object's apparent size.
    float4 world = float4(input.position, 0.0, 1.0) * uniforms.modelMatrix;
    out.position = world
        * uniforms.viewMatrix
        * uniforms.canvasMatrix;
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
    // A missing or zero-width bar must not create an opening at the origin.
    if (portalHalfWidth <= 0.0)
        return false;

    float dy = end.y - start.y;
    if (abs(dy) < 0.000001)
        return false;

    float t = -start.y / dy;
    if (t <= 0.0 || t >= 1.0)
        return false;

    float x = start.x + t * (end.x - start.x);
    return abs(x) <= portalHalfWidth;
}

inline bool intersectsEitherPortal(
    float2 worldPosition,
    constant ShaderUniforms &uniforms
) {
    float4 world = float4(worldPosition, 0.0, 1.0);
    float2 entrancePosition = (world * uniforms.worldToEntrance).xy;
    float2 exitPosition = (world * uniforms.worldToExit).xy;

    return intersectsPortal(uniforms.eyeInEntrance.xy, entrancePosition, uniforms.portalHalfWidths.x)
        || intersectsPortal(uniforms.eyeInExit.xy, exitPosition, uniforms.portalHalfWidths.y);
}

fragment float4 portal_fragment(
    VertexOut input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(1)]]
) {
    // Original player and vision keep pixels on the near side of the openings.
    if (intersectsEitherPortal(input.worldPosition, uniforms))
        discard_fragment();

    return uniforms.color;
}

fragment float4 portal_clone_fragment(
    VertexOut input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(1)]]
) {
    // Cloned player and vision use the complementary visibility mask.
    if (!intersectsEitherPortal(input.worldPosition, uniforms))
        discard_fragment();

    return uniforms.color;
}
