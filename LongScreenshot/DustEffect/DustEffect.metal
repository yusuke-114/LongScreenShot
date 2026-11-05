//
//  DustEffect.metal
//  LongScreenshot
//
//  GPU particle disintegration ("dust") effect for the capture chrome.
//
//    * A snapshot of a view is uploaded as a texture and conceptually cut into
//      a grid of cells, one particle per cell.
//    * Each particle gets a random direction, speed and lifetime, seeded from
//      its own index so no CPU-side setup pass is needed.
//    * A soft window sweeps down a shared vertical axis over time. A particle's
//      simulation only advances in proportion to how far the window has reached
//      it, so the image erodes from the top instead of exploding all at once.
//      The axis is shared across every piece in a dissolve, which is what makes
//      the selection border and the preview card crumble under one wave rather
//      than each running its own.
//    * Particles the window has not reached yet sit at zero offset with full
//      alpha, and their quads tile the source texture exactly. The untouched
//      part therefore renders pixel-identical to the original view, which is
//      what makes the hand-off invisible.
//

#include <metal_stdlib>

using namespace metal;

struct DustParticle {
    packed_float2 offset;
    packed_float2 velocity;
    float lifetime;
};

// Kept as a flat list of floats so the Swift mirror of this struct cannot
// disagree about alignment or padding.
struct DustConfig {
    float itemWidth;
    float itemHeight;
    float gridWidth;
    float gridHeight;
    float gravity;
    float minSpeed;
    float maxSpeed;
    float minLifetime;
    float maxLifetime;
    float waveWidth;
    float waveDuration;
    float fadeDuration;
    float verticalDirection;
    float phase;
    float timeStep;
    float seed;
    // Where this piece sits on the dissolve's shared sweep axis: 0 is the top
    // of the whole group, 1 the bottom.
    float sweepStart;
    float sweepSpan;
};

constant float2 quadVertices[6] = {
    float2(0.0, 0.0),
    float2(1.0, 0.0),
    float2(0.0, 1.0),
    float2(1.0, 0.0),
    float2(0.0, 1.0),
    float2(1.0, 1.0)
};

// PCG hash. Cheap, and good enough that neighbouring particle indices do not
// produce visibly correlated directions.
static inline uint dustHash(uint value) {
    uint state = value * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

static inline float dustRandom(thread uint &state) {
    state = dustHash(state);
    return float(state) * (1.0 / 4294967295.0);
}

// How much of the simulation a particle at `position` (0...1 down the sweep
// axis) is allowed to run, given the overall `progress` (0...1) of the sweep.
//
// The window starts fully above the group and travels past its bottom edge.
// Rows behind the window run at full speed, rows ahead of it are frozen, and
// rows inside it ramp up - that ramp is what gives the leading edge its
// crumbling look rather than a hard cut.
static inline float dustWaveActivation(float progress, float position, float waveWidth) {
    float width = max(waveWidth, 0.0001);
    float windowPosition = mix(-width, 1.0, progress);
    float windowT = clamp(position - windowPosition, 0.0, width) / width;
    return 1.0 - windowT;
}

kernel void dustInitialize(
    device DustParticle *particles [[buffer(0)]],
    constant DustConfig &config [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    uint count = uint(config.gridWidth) * uint(config.gridHeight);
    if (gid >= count) {
        return;
    }

    uint state = dustHash(gid + uint(config.seed) * 9781u);

    float angle = dustRandom(state) * 6.2831853;
    float speed = mix(config.minSpeed, config.maxSpeed, dustRandom(state));

    DustParticle particle;
    particle.offset = packed_float2(0.0, 0.0);
    particle.velocity = packed_float2(float2(cos(angle), sin(angle)) * speed);
    particle.lifetime = mix(config.minLifetime, config.maxLifetime, dustRandom(state));

    particles[gid] = particle;
}

kernel void dustUpdate(
    device DustParticle *particles [[buffer(0)]],
    constant DustConfig &config [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    uint columns = uint(config.gridWidth);
    uint count = columns * uint(config.gridHeight);
    if (gid >= count) {
        return;
    }

    float progress = clamp(config.phase / max(config.waveDuration, 0.0001), 0.0, 1.0);
    // Rows are numbered bottom-up in the item's local space, so invert to get a
    // top-down depth, then place it on the group's shared sweep axis.
    float row = float(gid / columns);
    float depth = 1.0 - (row + 0.5) / max(config.gridHeight, 1.0);
    float sweep = config.sweepStart + depth * config.sweepSpan;
    float activation = dustWaveActivation(progress, sweep, config.waveWidth);

    DustParticle particle = particles[gid];
    float step = config.timeStep * activation;

    particle.offset += particle.velocity * step;
    particle.velocity.y += config.gravity * config.verticalDirection * step;
    particle.lifetime = max(0.0, particle.lifetime - step);

    particles[gid] = particle;
}

struct DustVertexOut {
    float4 position [[position]];
    float2 uv;
    float alpha;
};

vertex DustVertexOut dustVertex(
    constant float4 &rect [[buffer(0)]],
    constant DustConfig &config [[buffer(1)]],
    const device DustParticle *particles [[buffer(2)]],
    uint vid [[vertex_id]],
    uint iid [[instance_id]]
) {
    uint columns = uint(config.gridWidth);
    float2 itemSize = float2(config.itemWidth, config.itemHeight);
    float2 cellSize = itemSize / float2(config.gridWidth, config.gridHeight);

    float2 cellOrigin = float2(float(iid % columns), float(iid / columns)) * cellSize;
    float2 corner = quadVertices[vid];

    DustVertexOut out;
    // UV comes from where the cell *was*, so each particle keeps carrying its
    // own piece of the original image around.
    out.uv = (cellOrigin + corner * cellSize) / itemSize;

    float2 local = cellOrigin + float2(particles[iid].offset) + corner * cellSize;
    // Local points -> the item's slot in the layer (0...1, y up) -> clip space.
    float2 normalized = float2(rect.x + local.x / itemSize.x * rect.z,
                               rect.y + local.y / itemSize.y * rect.w);
    out.position = float4(normalized * 2.0 - 1.0, 0.0, 1.0);

    out.alpha = clamp(particles[iid].lifetime / max(config.fadeDuration, 0.0001), 0.0, 1.0);

    return out;
}

fragment half4 dustFragment(
    DustVertexOut in [[stage_in]],
    texture2d<half, access::sample> sourceTexture [[texture(0)]]
) {
    constexpr sampler textureSampler(coord::normalized, address::clamp_to_edge, filter::linear);

    // The local space is y-up, the texture is y-down.
    half4 color = sourceTexture.sample(textureSampler, float2(in.uv.x, 1.0 - in.uv.y));

    // Source is premultiplied, so scaling the whole thing keeps it premultiplied.
    return color * half(in.alpha);
}
