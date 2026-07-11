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
    uint pad;
} pc;

uint linearIndex(ivec3 pos) {
    ivec3 gs = voxelWorldProperties.grid_size.xyz;
    return uint(pos.x + pos.y * gs.x + pos.z * gs.x * gs.y);
}

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
void main() {
    ivec3 gs = voxelWorldProperties.grid_size.xyz;
    uint slice_size = uint(gs.x * gs.z);
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= slice_size) return;

    // Decode 1D index to (x, z) at the given y_level
    int x = int(idx % uint(gs.x));
    int z = int(idx / uint(gs.x));
    ivec3 pos = ivec3(x, pc.y_level, z);

    if (!isValidPos(pos)) return;

    uint voxel_index = posToIndex(pos);
    Voxel current = getPreviousVoxel(voxel_index);

    if (pc.mode == 1u) {
        // Clear mode: only remove debug-type voxels (don't touch real entities or terrain)
        if (isVoxelType(current, VOXEL_TYPE_DEBUG)) {
            setBothVoxelBuffers(voxel_index, createAirVoxel());
        }
        return;
    }

    // Draw mode: only write markers in air cells
    if (!isVoxelAir(current)) return;

    uint dist = distBuffer.distData[linearIndex(pos)];
    if (dist == 0xFFFFu) return; // unreachable, don't draw

    // Color by distance: green (near) → yellow (mid) → red (far)
    float t = clamp(float(dist) / float(max(pc.max_distance, 1u)), 0.0, 1.0);
    vec3 color;
    if (t < 0.5) {
        color = mix(vec3(0.0, 1.0, 0.3), vec3(1.0, 1.0, 0.0), t * 2.0);
    } else {
        color = mix(vec3(1.0, 1.0, 0.0), vec3(1.0, 0.0, 0.0), (t - 0.5) * 2.0);
    }

    // Target cell: bright cyan
    if (dist == 0u) {
        color = vec3(0.0, 1.0, 1.0);
    }

    setBothVoxelBuffers(voxel_index, createVoxel(VOXEL_TYPE_DEBUG, color));
}
