#[compute]
#version 460

#include "../utility.glsl"
#include "../voxel_world.glsl"

layout(std430, set = 1, binding = 0) restrict buffer Params {
    vec4 camera_origin;
    vec4 camera_direction;
    vec4 hit_position;
    float near;
    float far;
    float radius;
    uint value;
} params;

const ivec3 neighbors[6] = ivec3[](
    ivec3( 1,  0,  0),
    ivec3(-1,  0,  0),
    ivec3( 0,  1,  0),
    ivec3( 0, -1,  0),
    ivec3( 0,  0,  1),
    ivec3( 0,  0, -1)
);

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
void main() {
    ivec3 pos = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 world_pos = ivec3(params.hit_position.xyz) + pos - ivec3(params.radius);
    if (!isValidPos(world_pos) || params.hit_position.w < 0) return;

    vec3 center = params.hit_position.xyz;
    float d = length(vec3(world_pos) - center);
    if (d >= params.radius) return;

    uint brick_index = getBrickIndex(world_pos);
    uint voxel_index = voxelBricks[brick_index].voxel_data_pointer * BRICK_VOLUME + getVoxelIndexInBrick(world_pos);
    Voxel center_voxel = getVoxel(voxel_index);
    bool center_is_air = isVoxelAir(center_voxel);

    // Count solid vs air neighbors
    int solid_count = 0;
    int air_count = 0;
    vec3 color_sum = vec3(0.0);
    uint dominant_type = VOXEL_TYPE_SOLID;

    for (int i = 0; i < 6; i++) {
        ivec3 neighbor_pos = world_pos + neighbors[i];
        if (!isValidPos(neighbor_pos)) {
            air_count++;
            continue;
        }

        uint neighbor_index = voxelBricks[getBrickIndex(neighbor_pos)].voxel_data_pointer * BRICK_VOLUME + getVoxelIndexInBrick(neighbor_pos);
        Voxel neighbor_voxel = getVoxel(neighbor_index);

        if (isVoxelAir(neighbor_voxel)) {
            air_count++;
        } else {
            solid_count++;
            color_sum += getVoxelColor(neighbor_voxel, neighbor_pos);
            dominant_type = (neighbor_voxel.data >> 24) & 0xFFu;
        }
    }

    // Only modify voxels near the surface (where there's a mix of air and solid)
    if (solid_count == 0 || air_count == 0) return;

    // Majority vote: if more neighbors are solid, become solid; if more are air, become air
    if (center_is_air && solid_count > 3) {
        // Fill in: this air voxel is mostly surrounded by solid — fill it
        vec3 avg_color = color_sum / float(solid_count);
        Voxel new_voxel = createVoxel(dominant_type, avg_color);
        setBothVoxelBuffers(voxel_index, new_voxel);
    } else if (!center_is_air && air_count > 3) {
        // Erode: this solid voxel is mostly surrounded by air — remove it
        setBothVoxelBuffers(voxel_index, createAirVoxel());
    }
}
