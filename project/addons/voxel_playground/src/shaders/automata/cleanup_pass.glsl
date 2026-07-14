#[compute]
#version 460

#include "../utility.glsl.inc"
#include "../voxel_world.glsl.inc"
#include "../voxel_elements.glsl.inc"

layout(local_size_x = 4, local_size_y = 2, local_size_z = 4) in;

shared uint localOccupancy[32];

void main() {
    ivec3 pos = ivec3(gl_GlobalInvocationID.xyz) * ivec3(2, 4, 2);
    
    uint brick_index = getBrickIndex(pos);
    uint id = gl_LocalInvocationIndex;      
    uint occupied = 0;
    
    for (int x = 0; x < 2; ++x) {
        for (int y = 0; y < 4; ++y) {
            for (int z = 0; z < 2; ++z) {
                ivec3 world_pos = pos + ivec3(x, y, z);
                if (!isValidPos(world_pos)) continue;       
                
                uint voxel_index = voxelBricks[brick_index].voxel_data_pointer * BRICK_VOLUME
                                    + getVoxelIndexInBrick(world_pos); 
                
                Voxel prev_voxel = getPreviousVoxel(voxel_index);
                if(!isVoxelAir(prev_voxel) && isTypeDynamic(getVoxelType(prev_voxel))) {
                    setPreviousVoxel(voxel_index, createAirVoxel());
                }

                // zero the consumed dynamics buffer: it becomes the write
                // target of the next pass, and the movement pass requires it
                // all-zero so atomicOr writes compose safely (see
                // voxel_elements.glsl.inc DYNAMICS ACCESS)
                setPreviousDynamics(voxel_index, 0u);

                occupied += isVoxelAir(getVoxel(voxel_index)) ? 0 : 1;
            }
        }
    }  

    localOccupancy[id] = occupied;
    barrier();
    
    if (id == 0u) {
        uint count = 0;
        for (uint i = 0u; i < 32u; ++i) {
            count += localOccupancy[i];
        }

        voxelBricks[brick_index].occupancy_count = count;
    }
}
