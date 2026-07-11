#[compute]
#version 460

#include "../utility.glsl"
#include "../voxel_world.glsl"

// 6 possible growth directions
ivec3 vine_directions[6] = ivec3[](
    ivec3(0, 1, 0),   // up
    ivec3(-1, 0, 0),  // left
    ivec3(1, 0, 0),   // right
    ivec3(0, 0, 1),   // forward
    ivec3(0, 0, -1),  // backward
    ivec3(0, -1, 0)   // down
);

// Check if a position has at least one solid neighbor to cling to
bool hasSolidNeighbor(ivec3 pos) {
    for (int i = 0; i < 6; i++) {
        ivec3 neighbor = pos + vine_directions[i];
        if (isValidPos(neighbor)) {
            Voxel v = getPreviousVoxel(posToIndex(neighbor));
            if (isVoxelSolid(v)) return true;
        }
    }
    return false;
}

// Count how many vine voxels surround a target position
int countVineNeighbors(ivec3 targetPos) {
    int count = 0;
    for (int i = 0; i < 6; i++) {
        ivec3 neighbor = targetPos + vine_directions[i];
        if (isValidPos(neighbor)) {
            Voxel v = getPreviousVoxel(posToIndex(neighbor));
            if (isVoxelType(v, VOXEL_TYPE_VINE)) {
                count++;
            }
        }
    }
    return count;
}

// Pick a growth direction with upward bias
// 40% up, 10% each sideways (x4 = 40%), 20% down
uint pickGrowthDirection(uvec4 random_value) {
    uint r = random_value.y % 100u;
    if (r < 40u) return 0u;       // up
    if (r < 50u) return 1u;       // left
    if (r < 60u) return 2u;       // right
    if (r < 70u) return 3u;       // forward
    if (r < 80u) return 4u;       // backward
    return 5u;                     // down
}

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
void main() {
    ivec3 pos = ivec3(gl_GlobalInvocationID.xyz);
    if (!isValidPos(pos)) return;

    uint brick_index = getBrickIndex(pos);
    uint voxel_index = voxelBricks[brick_index].voxel_data_pointer * BRICK_VOLUME + getVoxelIndexInBrick(pos);

    Voxel voxel_value = getPreviousVoxel(voxel_index);
    if (!isVoxelType(voxel_value, VOXEL_TYPE_VINE)) return;

    // Persist this vine voxel into the current buffer
    setVoxel(voxel_index, voxel_value);

    // Read energy from lower 8 bits
    uint energy = getVineEnergy(voxel_value);
    if (energy == 0u) return;

    // Probabilistic growth: ~6% chance per frame
    uvec4 random_value = hash(uvec4(pos, voxelWorldProperties.frame));
    if ((random_value.x % 16u) != 0u) return;

    // Pick growth direction with upward bias
    uint dir_index = pickGrowthDirection(random_value);
    ivec3 dir = vine_directions[dir_index];
    ivec3 newPos = pos + dir;

    if (!isValidPos(newPos)) return;

    uint new_voxel_index = posToIndex(newPos);
    Voxel target = getPreviousVoxel(new_voxel_index);

    // Only grow into air
    if (!isVoxelAir(target)) return;

    // Surface-clinging rule: target must have at least one solid neighbor
    if (!hasSolidNeighbor(newPos)) return;

    // NEW: Crowding Rule
    // A target air block should only be touching the parent vine (1 neighbor). 
    // If it touches > 1, growing here would fuse branches or create thick blobs.
    if (countVineNeighbors(newPos) > 1) return;

    // Place new vine tip with reduced energy
    Voxel new_vine = createVineVoxel(newPos, energy - 1u);

    // Thread-safe placement via atomic compare-and-swap
    uint expected = target.data;
    uint original;
    if (voxelWorldProperties.frame % 2 == 0)
        original = atomicCompSwap(voxelData[new_voxel_index].data, expected, new_vine.data);
    else
        original = atomicCompSwap(voxelData2[new_voxel_index].data, expected, new_vine.data);

    // NEW: Exhaustion Rule (Tip -> Stem)
    // If original == expected, our atomic swap was successful and WE spawned the child.
    if (original == expected) {
        // Overwrite the parent (this thread's voxel) in the current buffer 
        // with 0 energy so it stops growing. It becomes a passive stem.
        Voxel stem_vine = createVineVoxel(pos, 0u); 
        setVoxel(voxel_index, stem_vine);
    }
}
