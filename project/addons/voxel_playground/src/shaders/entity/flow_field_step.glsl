#[compute]
#version 460

#include "../utility.glsl.inc"
#include "../voxel_world.glsl.inc"

layout(std430, set = 1, binding = 0) buffer DistanceBuffer {
    uint distData[];
} distBuffer;

layout(push_constant) uniform PushConstants {
    uint current_step;
    uint steps_per_dispatch;
    uint pad0, pad1;
} pc;

const ivec3 DIRS[6] = ivec3[](
    ivec3( 1, 0, 0), ivec3(-1, 0, 0),
    ivec3( 0, 1, 0), ivec3( 0,-1, 0),
    ivec3( 0, 0, 1), ivec3( 0, 0,-1)
);

uint linearIndex(ivec3 pos) {
    ivec3 gs = voxelWorldProperties.grid_size.xyz;
    return uint(pos.x + pos.y * gs.x + pos.z * gs.x * gs.y);
}

bool isPassable(ivec3 pos) {
    if (!isValidPos(pos)) return false;
    uint voxel_idx = posToIndex(pos);
    Voxel v = getPreviousVoxel(voxel_idx);
    return isVoxelAir(v) || isVoxelEntity(v);
}

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
void main() {
    ivec3 gs = voxelWorldProperties.grid_size.xyz;
    uint total = uint(gs.x * gs.y * gs.z);
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= total) return;

    // Decode linear index to 3D position
    ivec3 pos = ivec3(
        int(idx % uint(gs.x)),
        int((idx / uint(gs.x)) % uint(gs.y)),
        int(idx / uint(gs.x * gs.y))
    );

    // Skip impassable cells
    if (!isPassable(pos)) return;

    uint my_dist = distBuffer.distData[idx];

    // Already visited — nothing to do
    if (my_dist != 0xFFFFu) return;

    // Check multiple BFS steps in one dispatch
    for (uint step = pc.current_step; step < pc.current_step + pc.steps_per_dispatch; step++) {
        if (my_dist != 0xFFFFu) break; // already claimed in an earlier step of this loop

        // Check if any face-neighbor has distance == step
        for (int d = 0; d < 6; d++) {
            ivec3 np = pos + DIRS[d];
            if (!isValidPos(np)) continue;
            uint ni = linearIndex(np);
            uint nd = distBuffer.distData[ni];
            if (nd == step) {
                my_dist = step + 1u;
                distBuffer.distData[idx] = my_dist;
                break;
            }
        }
    }
}
