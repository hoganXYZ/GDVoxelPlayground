#[compute]
#version 460

#include "../utility.glsl.inc"
#include "../voxel_world.glsl.inc"

// Distance buffer: 1 uint32 per voxel cell. 0xFFFF = unreachable, 0 = target.
layout(std430, set = 1, binding = 0) buffer DistanceBuffer {
    uint distData[];
} distBuffer;

layout(push_constant) uniform PushConstants {
    ivec4 target_pos; // xyz = target, w = unused
} pc;

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
void main() {
    uint idx = gl_GlobalInvocationID.x;
    uint total = uint(voxelWorldProperties.grid_size.x
                    * voxelWorldProperties.grid_size.y
                    * voxelWorldProperties.grid_size.z);

    if (idx >= total) return;

    // Set all cells to unreachable
    distBuffer.distData[idx] = 0xFFFFu;

    // Seed the target cell with distance 0
    ivec3 gs = voxelWorldProperties.grid_size.xyz;
    uint target_idx = uint(pc.target_pos.x
                         + pc.target_pos.y * gs.x
                         + pc.target_pos.z * gs.x * gs.y);
    if (idx == target_idx) {
        distBuffer.distData[idx] = 0u;
    }
}
