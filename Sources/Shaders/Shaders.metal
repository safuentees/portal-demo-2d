#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 worldPosition;
    float2 localPosition;
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
    float visionFeatherPixels;
    float2 coneSize;
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
    out.localPosition = input.position / uniforms.coneSize;

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

// Fade inward from the triangle's two sides and far edge. Its tip is at (0, 0).
inline float coneCoverage(float2 localPosition, float featherPixels) {
    float3 margins = float3(
        0.5 * localPosition.y - localPosition.x,
        0.5 * localPosition.y + localPosition.x,
        1.0 - localPosition.y
    );
    float3 widths = max(fwidth(margins) * featherPixels, float3(0.000001));
    float3 coverage = smoothstep(float3(0.0), widths, margins);
    return min(coverage.x, min(coverage.y, coverage.z));
}

inline float cross2D(float2 first, float2 second) {
    return first.x * second.y - first.y * second.x;
}

// Continuous coverage of the region beyond an opening, bounded by its two sightlines.
inline float portalCoverage(float2 eye, float2 point, float halfWidth, float featherPixels) {
    // These values are uniform for the draw, so every fragment takes the same branch.
    if (halfWidth <= 0.0 || eye.y == 0.0)
        return 0.0;

    float side = sign(eye.y);
    // The eye is off the plane, so neither ray can have zero length.
    float2 leftRay = normalize(float2(-halfWidth, 0.0) - eye);
    float2 rightRay = normalize(float2(halfWidth, 0.0) - eye);
    float2 toPoint = point - eye;
    float3 margins = float3(
        -side * point.y,
        side * cross2D(leftRay, toPoint),
        -side * cross2D(rightRay, toPoint)
    );

    // Derivatives convert each boundary's margin to pixels, without dividing by ray dy.
    float3 widths = max(fwidth(margins) * featherPixels, float3(0.000001));
    float3 coverage = smoothstep(-0.5 * widths, 0.5 * widths, margins);
    return min(coverage.x, min(coverage.y, coverage.z));
}

inline float eitherPortalCoverage(float2 worldPosition, constant ShaderUniforms &uniforms) {
    float4 world = float4(worldPosition, 0.0, 1.0);
    float2 entrancePosition = (world * uniforms.worldToEntrance).xy;
    float2 exitPosition = (world * uniforms.worldToExit).xy;
    float entranceCoverage = portalCoverage(
        uniforms.eyeInEntrance.xy, entrancePosition,
        uniforms.portalHalfWidths.x, uniforms.visionFeatherPixels
    );
    float exitCoverage = portalCoverage(
        uniforms.eyeInExit.xy, exitPosition,
        uniforms.portalHalfWidths.y, uniforms.visionFeatherPixels
    );
    // Union the openings without increasing opacity where their coverage overlaps.
    return max(entranceCoverage, exitCoverage);
}

fragment float4 portal_fragment(
    VertexOut input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(1)]]
) {
    if (uniforms.visionFeatherPixels > 0.0) {
        float visibility = 1.0 - eitherPortalCoverage(input.worldPosition, uniforms);
        float coverage = coneCoverage(input.localPosition, uniforms.visionFeatherPixels) * visibility;
        return float4(uniforms.color.rgb, uniforms.color.a * coverage);
    }

    // Original player and vision keep pixels on the near side of the openings.
    if (intersectsEitherPortal(input.worldPosition, uniforms))
        discard_fragment();

    return uniforms.color;
}

fragment float4 portal_clone_fragment(
    VertexOut input [[stage_in]],
    constant ShaderUniforms &uniforms [[buffer(1)]]
) {
    if (uniforms.visionFeatherPixels > 0.0) {
        float visibility = eitherPortalCoverage(input.worldPosition, uniforms);
        float coverage = coneCoverage(input.localPosition, uniforms.visionFeatherPixels) * visibility;
        return float4(uniforms.color.rgb, uniforms.color.a * coverage);
    }

    // Cloned player and vision use the complementary visibility mask.
    if (!intersectsEitherPortal(input.worldPosition, uniforms))
        discard_fragment();

    return uniforms.color;
}
