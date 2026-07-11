#[compute]
#version 460

#include "../utility.glsl.inc"
#include "../voxel_world.glsl.inc"

layout(std430, set = 1, binding = 0) buffer DistanceBuffer {
    uint distData[];
} distBuffer;

layout(push_constant) uniform PushConstants {
    int y_level;
    uint mode;          // 0 = draw, 1 = clear
    uint max_distance;
    uint line_spacing;  // cells between seed points (e.g. 4)
} pc;

uint linearIndex(ivec3 pos) {
    ivec3 gs = voxelWorldProperties.grid_size.xyz;
    return uint(pos.x + pos.y * gs.x + pos.z * gs.x * gs.y);
}

uint readDistance(ivec3 pos) {
    if (!isValidPos(pos)) return 0xFFFFu;
    return distBuffer.distData[linearIndex(pos)] & 0xFFFFu;
}

// XZ face neighbors for horizontal-plane flow tracing
const ivec3 XZ_NEIGHBORS[4] = ivec3[4](
    ivec3(1, 0, 0), ivec3(-1, 0, 0),
    ivec3(0, 0, 1), ivec3(0, 0, -1)
);

vec3 distanceToColor(uint dist) {
    if (dist == 0u) return vec3(0.0, 1.0, 1.0); // target = cyan

    float t = clamp(float(dist) / float(max(pc.max_distance, 1u)), 0.0, 1.0);
    if (t < 0.5) {
        return mix(vec3(0.0, 1.0, 0.3), vec3(1.0, 1.0, 0.0), t * 2.0);
    } else {
        return mix(vec3(1.0, 1.0, 0.0), vec3(1.0, 0.0, 0.0), (t - 0.5) * 2.0);
    }
}

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
void main() {
    ivec3 gs = voxelWorldProperties.grid_size.xyz;
    uint spacing = max(pc.line_spacing, 2u);

    if (pc.mode == 1u) {
        // Clear mode: sweep full Y-slice removing debug voxels
        uint slice_size = uint(gs.x * gs.z);
        uint idx = gl_GlobalInvocationID.x;
        if (idx >= slice_size) return;

        int x = int(idx % uint(gs.x));
        int z = int(idx / uint(gs.x));
        ivec3 pos = ivec3(x, pc.y_level, z);
        if (!isValidPos(pos)) return;

        uint vi = posToIndex(pos);
        if (isVoxelType(getPreviousVoxel(vi), VOXEL_TYPE_DEBUG)) {
            setBothVoxelBuffers(vi, createAirVoxel());
        }
        return;
    }

    // Draw mode: each thread is one seed point on a regular XZ grid
    uint seeds_x = (uint(gs.x) + spacing - 1u) / spacing;
    uint seeds_z = (uint(gs.z) + spacing - 1u) / spacing;
    uint total_seeds = seeds_x * seeds_z;

    uint seed_id = gl_GlobalInvocationID.x;
    if (seed_id >= total_seeds) return;

    int sx = int(seed_id % seeds_x) * int(spacing) + int(spacing / 2u);
    int sz = int(seed_id / seeds_x) * int(spacing) + int(spacing / 2u);

    ivec3 current = ivec3(sx, pc.y_level, sz);
    if (!isValidPos(current)) return;

    uint dist = readDistance(current);
    if (dist >= 0xFFFFu) return; // unreachable

    // Trace the streamline following steepest descent
    uint line_length = spacing;

    for (uint step = 0u; step <= line_length; step++) {
        // Place debug voxel at current position if it's air
        uint vi = posToIndex(current);
        Voxel v = getPreviousVoxel(vi);
        if (isVoxelAir(v)) {
            // Brightness fade along the line: bright at start (tail), dim at end (head)
            // This shows direction: entities flow from bright to dim
            float fade = 1.0 - float(step) / float(line_length) * 0.6;
            vec3 color = distanceToColor(dist) * fade;
            setBothVoxelBuffers(vi, createVoxel(VOXEL_TYPE_DEBUG, color));
        }

        if (dist == 0u) break; // reached target

        // Find XZ neighbor with lowest distance (steepest descent)
        uint best_dist = dist;
        ivec3 best_pos = current;

        for (int n = 0; n < 4; n++) {
            ivec3 neighbor = current + XZ_NEIGHBORS[n];
            uint nd = readDistance(neighbor);
            if (nd < best_dist) {
                best_dist = nd;
                best_pos = neighbor;
            }
        }

        // Stuck (no better neighbor) — stop tracing
        if (best_pos == current) break;

        current = best_pos;
        dist = best_dist;
    }
}
