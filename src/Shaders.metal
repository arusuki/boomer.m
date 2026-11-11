#include <metal_stdlib>
using namespace metal;

// Same field order/alignment as BMUniforms in Renderer.h (64 bytes).
struct Uniforms {
    float2 viewport, offset, imageSize, cursor;
    float scale, radius, dim, mirror;
    float linearFilter, padding0, padding1, padding2;
};
struct Vertex { float4 position [[position]]; float2 uv; };
vertex Vertex fullscreenVertex(uint id [[vertex_id]]) {
    float2 uv = float2((id << 1) & 2, id & 2);
    return {float4(uv * float2(2, -2) + float2(-1, 1), 0, 1), uv};
}
fragment float4 screenFragment(Vertex in [[stage_in]],
    texture2d<float> screen [[texture(0)]], constant Uniforms &u [[buffer(0)]]) {
    float2 p = in.uv * u.viewport;
    float2 origin = (u.viewport - u.imageSize) * 0.5;
    float2 uv = ((p - u.offset) / u.scale - origin) / u.imageSize;
    if (u.mirror > 0.5) uv.x = 1 - uv.x;
    constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 color = float3(0.035, 0.04, 0.05);
    if (all(uv >= 0.0) && all(uv < 1.0)) {
        float4 sample = u.linearFilter > 0.5 ? screen.sample(linearSampler, uv) : screen.sample(nearestSampler, uv);
        color = sample.rgb + color * (1 - sample.a); // Premultiplied input.
    }
    float shadow = smoothstep(max(0.0f, u.radius - 2), u.radius + 2, distance(p, u.cursor));
    return float4(color * (1 - u.dim * shadow), 1);
}
