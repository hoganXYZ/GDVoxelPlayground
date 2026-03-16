#[compute]
#version 460

#include "../utility.glsl.inc"
#include "../voxel_world.glsl.inc"

// Entity buffer layout:
//   [0]       uint  active_count
//   [1..7]    uint  padding (align first entity to 32 bytes)
//   [8..]     GPUEntity structs (8 uints = 32 bytes each)
//
// GPUEntity layout (matches C++ EntityManager::GPUEntity):
//   int position[3]   - grid position xyz
//   int state          - packed: entity_type(8) | current_state(8) | carry_type(8) | health(8)
//   int target[3]      - move target xyz
//   int flags          - packed: last_move_dir(3) | stuck_counter(4) | blocked_by_entity(1) | flow_snapshot(8) | squad_id(16)

layout(std430, set = 1, binding = 0) buffer EntityBuffer {
    uint data[];
} entityBuffer;

// Flow field distance buffer: 1 uint32 per voxel cell (linear indexing).
// Distance 0 = target, 0xFFFF = unreachable.
layout(std430, set = 1, binding = 1) buffer FlowFieldBuffer {
    uint distData[];
} flowField;

const uint HEADER_UINTS = 8u;        // 32 bytes / 4 = 8 uints
const uint ENTITY_UINTS = 8u;        // 32 bytes / 4 = 8 uints

const uint STATE_IDLE = 0u;
const uint STATE_MOVING = 1u;

const vec3 ENTITY_COLOR = vec3(0.9, 0.3, 0.2); // red-orange, easy to spot

// --- Flow field helpers (declared early so entity voxel coloring can use them) ---

uint ffLinearIndex(ivec3 pos) {
    ivec3 gs = voxelWorldProperties.grid_size.xyz;
    return uint(pos.x + pos.y * gs.x + pos.z * gs.x * gs.y);
}

uint ffReadDistance(ivec3 pos) {
    if (!isValidPos(pos)) return 0xFFFFu;
    return flowField.distData[ffLinearIndex(pos)];
}

// ---------------------------------------------------------------------------------

ivec3 getEntityPosition(uint entity_id) {
    uint base = HEADER_UINTS + entity_id * ENTITY_UINTS;
    return ivec3(
        int(entityBuffer.data[base + 0u]),
        int(entityBuffer.data[base + 1u]),
        int(entityBuffer.data[base + 2u])
    );
}

void setEntityPosition(uint entity_id, ivec3 pos) {
    uint base = HEADER_UINTS + entity_id * ENTITY_UINTS;
    entityBuffer.data[base + 0u] = uint(pos.x);
    entityBuffer.data[base + 1u] = uint(pos.y);
    entityBuffer.data[base + 2u] = uint(pos.z);
}

ivec3 getEntityTarget(uint entity_id) {
    uint base = HEADER_UINTS + entity_id * ENTITY_UINTS;
    return ivec3(
        int(entityBuffer.data[base + 4u]),
        int(entityBuffer.data[base + 5u]),
        int(entityBuffer.data[base + 6u])
    );
}

uint getEntityState(uint entity_id) {
    uint base = HEADER_UINTS + entity_id * ENTITY_UINTS;
    return (entityBuffer.data[base + 3u] >> 16u) & 0xFFu;
}

// Last move direction: stored in lowest 3 bits of flags (word 7).
// Values: 0 = none, 1-6 = direction index + 1.
// Directions are paired as opposites: 0/1 (+X/-X), 2/3 (+Y/-Y), 4/5 (+Z/-Z).
// The reverse of direction d is d ^ 1.
uint getLastMoveDir(uint entity_id) {
    uint base = HEADER_UINTS + entity_id * ENTITY_UINTS;
    return entityBuffer.data[base + 7u] & 0x7u;
}

void setLastMoveDir(uint entity_id, uint dir_index) {
    uint base = HEADER_UINTS + entity_id * ENTITY_UINTS;
    entityBuffer.data[base + 7u] = (entityBuffer.data[base + 7u] & ~0x7u) | ((dir_index + 1u) & 0x7u);
}

// Stuck counter: bits 3-6 (4 bits, values 0-15)
uint getStuckCounter(uint entity_id) {
    uint base = HEADER_UINTS + entity_id * ENTITY_UINTS;
    return (entityBuffer.data[base + 7u] >> 3u) & 0xFu;
}

void setStuckCounter(uint entity_id, uint count) {
    uint base = HEADER_UINTS + entity_id * ENTITY_UINTS;
    uint flags = entityBuffer.data[base + 7u];
    flags = (flags & ~(0xFu << 3u)) | ((count & 0xFu) << 3u);
    entityBuffer.data[base + 7u] = flags;
}

// Blocked-by-entity flag: bit 7
bool getBlockedByEntity(uint entity_id) {
    uint base = HEADER_UINTS + entity_id * ENTITY_UINTS;
    return (entityBuffer.data[base + 7u] & (1u << 7u)) != 0u;
}

void setBlockedByEntity(uint entity_id, bool blocked) {
    uint base = HEADER_UINTS + entity_id * ENTITY_UINTS;
    uint flags = entityBuffer.data[base + 7u];
    if (blocked) flags |= (1u << 7u);
    else flags &= ~(1u << 7u);
    entityBuffer.data[base + 7u] = flags;
}

// Flow distance snapshot: bits 8-15 (8 bits, 0-254 = distance, 255 = uninitialized/unreachable)
uint getFlowSnapshot(uint entity_id) {
    uint base = HEADER_UINTS + entity_id * ENTITY_UINTS;
    return (entityBuffer.data[base + 7u] >> 8u) & 0xFFu;
}

void setFlowSnapshot(uint entity_id, uint dist) {
    uint base = HEADER_UINTS + entity_id * ENTITY_UINTS;
    uint clamped = min(dist, 0xFFu);
    uint flags = entityBuffer.data[base + 7u];
    flags = (flags & ~(0xFFu << 8u)) | (clamped << 8u);
    entityBuffer.data[base + 7u] = flags;
}

Voxel createEntityVoxel() {
    return createVoxel(VOXEL_TYPE_ENTITY, ENTITY_COLOR);
}

// Create entity voxel colored by flow field distance (green=near, red=far, white=unreachable)
Voxel createEntityVoxelWithDistance(ivec3 pos) {
    uint dist = ffReadDistance(pos);
    if (dist == 0xFFFFu) return createVoxel(VOXEL_TYPE_ENTITY, vec3(1.0, 1.0, 1.0)); // white = unreachable
    float t = clamp(float(dist) / 200.0, 0.0, 1.0);
    // Green (near) → Yellow (mid) → Red (far)
    vec3 color = mix(vec3(0.1, 1.0, 0.2), vec3(1.0, 0.15, 0.1), t);
    return createVoxel(VOXEL_TYPE_ENTITY, color);
}

bool isDebugVoxel(Voxel v) {
    return getVoxelType(v) == VOXEL_TYPE_DEBUG;
}

// --- Flow field navigation ---

// Check if the voxel at pos is an entity
bool isEntityAt(ivec3 pos) {
    if (!isValidPos(pos)) return false;
    uint brick_index = getBrickIndex(pos);
    uint voxel_index = voxelBricks[brick_index].voxel_data_pointer * BRICK_VOLUME
                     + getVoxelIndexInBrick(pos);
    Voxel v = getPreviousVoxel(voxel_index);
    return isVoxelEntity(v);
}

// Follow the flow field gradient: step toward the face-neighbor with the smallest distance.
// Returns ivec3(0) if at the target or unreachable.
// Check if a position has any solid neighbor on faces or diagonals (26-neighbor)
bool hasAdjacentSolid(ivec3 pos) {
    for (int dx = -1; dx <= 1; dx++) {
        for (int dy = -1; dy <= 1; dy++) {
            for (int dz = -1; dz <= 1; dz++) {
                if (dx == 0 && dy == 0 && dz == 0) continue;
                ivec3 np = pos + ivec3(dx, dy, dz);
                if (!isValidPos(np)) continue;
                uint ni = voxelBricks[getBrickIndex(np)].voxel_data_pointer * BRICK_VOLUME
                        + getVoxelIndexInBrick(np);
                Voxel nv = getPreviousVoxel(ni);
                if (!isVoxelAir(nv) && !isVoxelEntity(nv) && !isVoxelType(nv, VOXEL_TYPE_DEBUG)) return true;
            }
        }
    }
    return false;
}

// last_move_dir: 0 = none, 1-6 = direction index + 1 (as stored by setLastMoveDir).
// Returns the chosen direction and writes the chosen direction index into out_dir_index
// (or -1 if no move). Caller is responsible for calling setLastMoveDir on successful move.
ivec3 computeFlowFieldStep(ivec3 pos, uint noise, uint last_move_dir, out int out_dir_index) {
    out_dir_index = -1;
    uint my_dist = ffReadDistance(pos);
    if (my_dist == 0u) return ivec3(0);       // already at target
    if (my_dist == 0xFFFFu) return ivec3(0);  // unreachable

    // The reverse of the last move direction. If last_move_dir is L (1-6),
    // the actual direction index was L-1, and its reverse is (L-1)^1.
    uint reverse_dir = (last_move_dir > 0u) ? ((last_move_dir - 1u) ^ 1u) : 0xFFu;

    ivec3 best_dir = ivec3(0);
    uint best_cost = my_dist;
    int best_idx = -1;

    ivec3 dirs[6] = ivec3[](
        ivec3( 1, 0, 0), ivec3(-1, 0, 0),
        ivec3( 0, 1, 0), ivec3( 0,-1, 0),
        ivec3( 0, 0, 1), ivec3( 0, 0,-1)
    );

    // ~10% chance to pick a random valid downhill direction instead of the best,
    // breaking deadlocks where two entities block each other. 
    bool use_random = (noise % 10u) == 0u;
    uint random_pick = (noise >> 4u) % 6u;
    ivec3 random_dir = ivec3(0);
    int random_idx = -1;

    for (int d = 0; d < 6; d++) {
        ivec3 candidate = pos + dirs[d];
        uint nd = ffReadDistance(candidate);
        if (nd >= my_dist) continue;

        // Don't move upward unless the destination has a solid surface to touch
        if (dirs[d].y > 0 && !hasAdjacentSolid(candidate)) continue;

        // Penalize reversing last move direction: treat it as 2 steps further,
        // so the entity only backtracks if there's truly no other option.
        uint cost = nd;
        if (uint(d) == reverse_dir) cost += 2u;

        if (cost < best_cost) {
            best_cost = cost;
            best_dir = dirs[d];
            best_idx = d;
        }

        // Remember a random valid downhill direction for jitter
        if (uint(d) == random_pick) {
            random_dir = dirs[d];
            random_idx = d;
        }
    }

    if (use_random && random_idx >= 0) {
        out_dir_index = random_idx;
        return random_dir;
    }
    out_dir_index = best_idx;
    return best_dir;
}

// Greedy fallback: move along the axis with the largest delta toward target.
ivec3 computeStepToward(ivec3 pos, ivec3 target) {
    ivec3 delta = target - pos;
    if (delta == ivec3(0)) return ivec3(0);

    ivec3 absDelta = abs(delta);
    ivec3 step = ivec3(0);

    if (absDelta.x >= absDelta.y && absDelta.x >= absDelta.z) {
        step.x = (delta.x > 0) ? 1 : -1;
    } else if (absDelta.y >= absDelta.x && absDelta.y >= absDelta.z) {
        step.y = (delta.y > 0) ? 1 : -1;
    } else {
        step.z = (delta.z > 0) ? 1 : -1;
    }
    return step;
}

// Attempt to move entity voxel from old_pos to new_pos via atomicCompSwap.
// Returns true if the move succeeded.
bool tryMoveEntity(ivec3 old_pos, ivec3 new_pos, uint entity_voxel_data) {
    if (!isValidPos(new_pos)) return false;

    uint new_brick_index = getBrickIndex(new_pos);
    uint new_voxel_index = voxelBricks[new_brick_index].voxel_data_pointer * BRICK_VOLUME
                         + getVoxelIndexInBrick(new_pos);

    Voxel target_voxel = getPreviousVoxel(new_voxel_index);

    // Can only move into air or debug markers
    if (!isVoxelAir(target_voxel) && !isDebugVoxel(target_voxel)) return false;

    uint expected = target_voxel.data;
    uint original;

    // atomicCompSwap into the active write buffer (same pattern as liquid.glsl)
    if (voxelWorldProperties.frame % 2 == 0)
        original = atomicCompSwap(voxelData[new_voxel_index].data, expected, entity_voxel_data);
    else
        original = atomicCompSwap(voxelData2[new_voxel_index].data, expected, entity_voxel_data);

    if (original == expected) {
        // Move succeeded — clear old position
        uint old_brick_index = getBrickIndex(old_pos);
        uint old_voxel_index = voxelBricks[old_brick_index].voxel_data_pointer * BRICK_VOLUME
                             + getVoxelIndexInBrick(old_pos);
        setBothVoxelBuffers(old_voxel_index, createAirVoxel());

        // Write new position to both buffers so it persists across ping-pong
        setBothVoxelBuffers(new_voxel_index, Voxel(entity_voxel_data));

        return true;
    }

    return false;
}

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
void main() {
    uint entity_id = gl_GlobalInvocationID.x;
    uint active_count = entityBuffer.data[0];
    if (entity_id >= active_count) return;

    ivec3 pos = getEntityPosition(entity_id);
    ivec3 target = getEntityTarget(entity_id);

    // Stochastic update: not every entity moves every frame.
    // This spreads load and makes movement look more natural.
    uvec4 rng = hash(uvec4(pos, voxelWorldProperties.frame));
    if ((rng.x % 4u) != 0u) return; // ~25% of entities move each frame

    // Ensure the entity voxel exists at its current position
    if (isValidPos(pos)) {
        uint brick_index = getBrickIndex(pos);
        uint voxel_index = voxelBricks[brick_index].voxel_data_pointer * BRICK_VOLUME
                         + getVoxelIndexInBrick(pos);
        Voxel current = getPreviousVoxel(voxel_index);

        // If our cell is air (entity was displaced or first frame), place entity voxel
        if (isVoxelAir(current) || isDebugVoxel(current)) {
            setBothVoxelBuffers(voxel_index, createEntityVoxelWithDistance(pos));
        }
    }

    Voxel entity_voxel = createEntityVoxelWithDistance(pos);

    // DEBUG: Entity 0 places a bright yellow marker column at target
    if (entity_id == 0u) {
        for (int dy = 0; dy < 5; dy++) {
            ivec3 marker_pos = target + ivec3(0, dy, 0);
            if (isValidPos(marker_pos)) {
                uint mvi = posToIndex(marker_pos);
                setBothVoxelBuffers(mvi, createVoxel(VOXEL_TYPE_ENTITY, vec3(1.0, 1.0, 0.0)));
            }
        }
    }

    // Gravity: fall if not touching any solid voxel (26-neighbor check)
    bool grounded = false;
    ivec3 neighbors[18] = ivec3[](
        // Face neighbors
        ivec3(-1,0,0), ivec3(1,0,0),
        ivec3(0,-1,0), ivec3(0,1,0),
        ivec3(0,0,-1), ivec3(0,0,1),
        // Edge neighbors
        ivec3(-1,-1,0), ivec3(1,-1,0), ivec3(-1,1,0), ivec3(1,1,0),
        ivec3(-1,0,-1), ivec3(1,0,-1), ivec3(-1,0,1), ivec3(1,0,1),
        ivec3(0,-1,-1), ivec3(0,1,-1), ivec3(0,-1,1), ivec3(0,1,1)
        // Corner neighbors
        // ivec3(-1,-1,-1), ivec3(1,-1,-1), ivec3(-1,1,-1), ivec3(1,1,-1),
        // ivec3(-1,-1,1), ivec3(1,-1,1), ivec3(-1,1,1), ivec3(1,1,1)
    );
    for (int n = 0; n < 18; n++) {
        ivec3 np = pos + neighbors[n];
        // if (!isValidPos(np)) { grounded = true; break; } // world edge counts as solid
        uint nb_idx = voxelBricks[getBrickIndex(np)].voxel_data_pointer * BRICK_VOLUME
                    + getVoxelIndexInBrick(np);
        Voxel nv = getPreviousVoxel(nb_idx);
        if (!isVoxelAir(nv) && !isVoxelEntity(nv)) { grounded = true; break; }
    }

    if (!grounded) {
        ivec3 below = pos + ivec3(0, -1, 0);
        if (tryMoveEntity(pos, below, entity_voxel.data)) {
            setEntityPosition(entity_id, below);
            return;
        }
    }

    // Move toward target using flow field (with greedy fallback)
    uint last_dir = getLastMoveDir(entity_id);
    int chosen_dir_idx;
    ivec3 step = computeFlowFieldStep(pos, rng.z, last_dir, chosen_dir_idx);
    if (step == ivec3(0)) {
        step = computeStepToward(pos, target);
    }
    if (step == ivec3(0)) return; // already at target

    // Read progress tracking state
    uint snapshot = getFlowSnapshot(entity_id);
    uint stuck = getStuckCounter(entity_id);

    ivec3 new_pos = pos + step;

    if (tryMoveEntity(pos, new_pos, entity_voxel.data)) {
        // Move succeeded
        setEntityPosition(entity_id, new_pos);
        if (chosen_dir_idx >= 0) setLastMoveDir(entity_id, uint(chosen_dir_idx));
        setBlockedByEntity(entity_id, false);

        // Progress check: did we get closer to the target?
        uint new_dist = min(ffReadDistance(new_pos), 0xFFu);
        if (new_dist < snapshot || snapshot == 0xFFu) {
            // Made progress (or first snapshot)
            setStuckCounter(entity_id, 0u);
            setFlowSnapshot(entity_id, new_dist);
        } else {
            // Moved but didn't make progress (lateral/backtrack)
            setStuckCounter(entity_id, min(stuck + 1u, 15u));
        }
    } else {
        // Move failed — determine what blocked us
        bool entity_blocking = isEntityAt(new_pos);

        if (entity_blocking) {
            // Blocked by another entity: WAIT instead of bouncing laterally
            stuck = min(stuck + 1u, 15u);
            setStuckCounter(entity_id, stuck);
            setBlockedByEntity(entity_id, true);

            // Deadlock breaker: after threshold, one entity yields via random lateral step
            const uint DEADLOCK_THRESHOLD = 8u;
            if (stuck >= DEADLOCK_THRESHOLD) {
                // Tiebreaker: alternate who yields each frame using entity_id parity + frame
                bool should_yield = ((entity_id + voxelWorldProperties.frame) & 1u) != 0u;
                if (should_yield) {
                    ivec3 lateral_dirs[4] = ivec3[](
                        ivec3(1, 0, 0), ivec3(-1, 0, 0),
                        ivec3(0, 0, 1), ivec3(0, 0, -1)
                    );
                    uint dir_idx = rng.y % 4u;
                    ivec3 alt = pos + lateral_dirs[dir_idx];
                    if (tryMoveEntity(pos, alt, entity_voxel.data)) {
                        setEntityPosition(entity_id, alt);
                        setStuckCounter(entity_id, 0u);
                        setFlowSnapshot(entity_id, min(ffReadDistance(alt), 0xFFu));
                    }
                }
            }
        } else {
            // Blocked by terrain: try a random lateral step (existing behavior)
            setBlockedByEntity(entity_id, false);
            ivec3 lateral_dirs[6] = ivec3[](
                ivec3(1, 0, 0), ivec3(-1, 0, 0),
                ivec3(0, 0, 1), ivec3(0, 0, -1),
                ivec3(0, 1, 0), ivec3(0, -1, 0)
            );
            uint dir_idx = rng.y % 6u;
            ivec3 alt = pos + lateral_dirs[dir_idx];
            if (tryMoveEntity(pos, alt, entity_voxel.data)) {
                setEntityPosition(entity_id, alt);
            }
        }
    }
}
