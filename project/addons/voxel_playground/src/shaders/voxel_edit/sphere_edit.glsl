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

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
void main() {
    ivec3 pos = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 world_pos = ivec3(params.hit_position.xyz) + pos - ivec3(params.radius);
    if (!isValidPos(world_pos) || params.hit_position.w < 0) return;

    vec3 center = params.hit_position.xyz;
    float d = length(vec3(world_pos) - center);

    if (d < params.radius) {
        uint brick_index = getBrickIndex(world_pos);
        uint voxel_index = voxelBricks[brick_index].voxel_data_pointer * BRICK_VOLUME + getVoxelIndexInBrick(world_pos);     
        bool isAir = isVoxelAir(getVoxel(voxel_index));

        // value encoding:
        //   Legacy: value 0-5 (material selection index, hardcoded colors)
        //   Custom: (voxel_type << 24) | (1 << 16) | color16
        //     bit 16 = custom color flag
        //     bits 0-15 = 16-bit packed HSV color
        //     bits 24-31 = actual voxel type constant

        Voxel voxel = createAirVoxel();
        bool has_custom_color = (params.value & (1u << 16u)) != 0u;

        if (has_custom_color) {
            uint voxel_type = (params.value >> 24u) & 0xFFu;
            uint color16 = params.value & 0xFFFFu;
            // Pack voxel data directly to avoid HSV→RGB→HSV round-trip precision loss
            voxel.data = int((voxel_type << 24u) | (color16 << 8u));
            if (voxel_type == VOXEL_TYPE_VINE) {
                voxel.data |= 15; // energy
            }
        } else {
            // Legacy path: material selection index with default colors
            if(params.value == 1u)
                voxel = createRockVoxel(world_pos);
            if(params.value == 2u)
                voxel = createSandVoxel(world_pos);
            if(params.value == 3u)
                voxel = createWaterVoxel(world_pos);
            if(params.value == 4u)
                voxel = createLavaVoxel(world_pos);
            if(params.value == 5u)
                voxel = createVineVoxel(world_pos, 15u);
        }

        if(isAir ^^ isVoxelAir(voxel))
            setBothVoxelBuffers(voxel_index, voxel);
    }
}
