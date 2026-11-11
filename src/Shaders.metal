#include <metal_stdlib>
using namespace metal;

// Same field order/alignment as BMUniforms in Renderer.h (64 bytes).
struct Uniforms {
    float2 viewport, offset, imageSize, cursor;
    float scale, radius, dim, mirror;
    float filterMode, padding0, padding1, padding2;
};

struct Vertex {
    float4 position [[position]];
    float2 uv;
};

vertex Vertex fullscreenVertex(uint id [[vertex_id]]) {
    float2 uv = float2((id << 1) & 2, id & 2);
    return {float4(uv * float2(2, -2) + float2(-1, 1), 0, 1), uv};
}

// Interpolating Catmull-Rom kernel: preserves texel centers and gives a
// narrower edge transition than bilinear filtering when magnified.
static float4 cubicWeights(float t) {
    float t2 = t * t, t3 = t2 * t;
    return float4(-0.5 * t + t2 - 0.5 * t3, 1.0 - 2.5 * t2 + 1.5 * t3,
                  0.5 * t + 2.0 * t2 - 1.5 * t3, -0.5 * t2 + 0.5 * t3);
}

static float4 sampleBicubic(texture2d<float> screen, float2 uv) {
    float2 size = float2(screen.get_width(), screen.get_height());
    float2 position = uv * size - 0.5;
    float2 base = floor(position), fraction = position - base;
    float4 wx = cubicWeights(fraction.x), wy = cubicWeights(fraction.y);
    constexpr sampler pointSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float4 result = 0, localMin = float4(1), localMax = float4(0);
    for (int y = 0; y < 4; ++y) {
        for (int x = 0; x < 4; ++x) {
            float4 texel = screen.sample(pointSampler, (base + float2(x - 1, y - 1) + 0.5) / size);
            result += texel * wx[x] * wy[y];
            if (x >= 1 && x <= 2 && y >= 1 && y <= 2) {
                localMin = min(localMin, texel);
                localMax = max(localMax, texel);
            }
        }
    }
    // Negative cubic lobes otherwise produce halos around high-contrast text.
    result = clamp(result, localMin, localMax);
    result.rgb = min(result.rgb, float3(result.a)); // Keep premultiplied alpha valid.
    return result;
}

fragment float4 screenFragment(Vertex in [[stage_in]], texture2d<float> screen [[texture(0)]],
                               constant Uniforms &u [[buffer(0)]]) {
    float2 p = in.uv * u.viewport;
    float2 origin = (u.viewport - u.imageSize) * 0.5;
    float2 uv = ((p - u.offset) / u.scale - origin) / u.imageSize;
    if (u.mirror > 0.5)
        uv.x = 1 - uv.x;
    float2 textureSize = float2(screen.get_width(), screen.get_height());
    float footprint = max(length(dfdx(uv) * textureSize), length(dfdy(uv) * textureSize));
    constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 color = float3(0.035, 0.04, 0.05);
    if (all(uv >= 0.0) && all(uv < 1.0)) {
        float4 sample;
        if (u.filterMode > 1.5 && footprint < 1.0)
            sample = sampleBicubic(screen, uv);
        else if (u.filterMode > 0.5)
            sample = screen.sample(linearSampler, uv);
        else
            sample = screen.sample(nearestSampler, uv);
        color = sample.rgb + color * (1 - sample.a); // Premultiplied input.
    }
    float shadow = smoothstep(max(0.0f, u.radius - 2), u.radius + 2, distance(p, u.cursor));
    return float4(color * (1 - u.dim * shadow), 1);
}
