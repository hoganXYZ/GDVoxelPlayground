#[compute]
#version 460

#include "../utility.glsl.inc"
#include "../voxel_world.glsl.inc"

// Entity buffer layout:
//   [0]       uint  active_count
//   [1..7]    uint  padding (align first entity to 32 bytes / 8 uints)
//   [8..]     GPUEntity structs (12 uints = 48 bytes each)
//
// GPUEntity layout (matches C++ EntityManager::GPUEntity):
//   float position[3]   - continuous grid-space position
//   float velocity[3]   - velocity in grid units per timestep
//   int   target[3]     - flow field target (integer grid cell)
//   int   state         - packed: entity_type(8) | current_state(8) | unused(8) | health(8)
//   int   flags         - packed: squad_id(16) | unused(16)
//   int   _pad          - alignment padding

layout(std430, set = 1, binding = 0) buffer EntityBuffer {
    uint data[];
} entityBuffer;

// Flow field distance buffer: 1 uint32 per voxel cell (linear indexing).
// Distance 0 = target, 0xFFFF = unreachable.
layout(std430, set = 1, binding = 1) buffer FlowFieldBuffer {
    uint distData[];
} flowField;

const uint HEADER_UINTS = 8u;        // 32 bytes / 4 = 8 uints
const uint ENTITY_UINTS = 12u;       // 48 bytes / 4 = 12 uints

// ---- Tuning parameters ----
const float FLOW_WEIGHT        = 100.0;
const float SEPARATION_WEIGHT  = 80.0;
const float COHESION_WEIGHT    = 1.0;
const float GRAVITY            = -98.0;
const float DAMPING            = 0.98;
const float MAX_SPEED          = 100.0;
const float SEPARATION_RADIUS  = 1.0;
const float COHESION_RADIUS    = 8.0;
const float GROUND_CHECK_DIST  = 0.6;
const float DT                 = 0.016; // fixed timestep (~60fps)

// ---- Entity accessors (float positions via bit reinterpretation) ----

vec3 getEntityPosition(uint id) {
    uint base = HEADER_UINTS + id * ENTITY_UINTS;
    return vec3(
        uintBitsToFloat(entityBuffer.data[base + 0u]),
        uintBitsToFloat(entityBuffer.data[base + 1u]),
        uintBitsToFloat(entityBuffer.data[base + 2u])
    );
}

void setEntityPosition(uint id, vec3 pos) {
    uint base = HEADER_UINTS + id * ENTITY_UINTS;
    entityBuffer.data[base + 0u] = floatBitsToUint(pos.x);
    entityBuffer.data[base + 1u] = floatBitsToUint(pos.y);
    entityBuffer.data[base + 2u] = floatBitsToUint(pos.z);
}

vec3 getEntityVelocity(uint id) {
    uint base = HEADER_UINTS + id * ENTITY_UINTS;
    return vec3(
        uintBitsToFloat(entityBuffer.data[base + 3u]),
        uintBitsToFloat(entityBuffer.data[base + 4u]),
        uintBitsToFloat(entityBuffer.data[base + 5u])
    );
}

void setEntityVelocity(uint id, vec3 vel) {
    uint base = HEADER_UINTS + id * ENTITY_UINTS;
    entityBuffer.data[base + 3u] = floatBitsToUint(vel.x);
    entityBuffer.data[base + 4u] = floatBitsToUint(vel.y);
    entityBuffer.data[base + 5u] = floatBitsToUint(vel.z);
}

ivec3 getEntityTarget(uint id) {
    uint base = HEADER_UINTS + id * ENTITY_UINTS;
    return ivec3(
        int(entityBuffer.data[base + 6u]),
        int(entityBuffer.data[base + 7u]),
        int(entityBuffer.data[base + 8u])
    );
}

// ---- Flow field helpers ----

uint ffLinearIndex(ivec3 pos) {
    ivec3 gs = voxelWorldProperties.grid_size.xyz;
    return uint(pos.x + pos.y * gs.x + pos.z * gs.x * gs.y);
}

uint ffReadDistance(ivec3 pos) {
    if (!isValidPos(pos)) return 0xFFFFu;
    return flowField.distData[ffLinearIndex(pos)];
}

// Compute flow field gradient via central differences at the nearest grid cell.
// Returns a normalized direction pointing downhill (toward the target).
vec3 computeFlowGradient(vec3 fpos) {
    ivec3 pos = ivec3(floor(fpos));
    float dx = float(ffReadDistance(pos + ivec3(1, 0, 0))) - float(ffReadDistance(pos + ivec3(-1, 0, 0)));
    float dy = float(ffReadDistance(pos + ivec3(0, 1, 0))) - float(ffReadDistance(pos + ivec3(0, -1, 0)));
    float dz = float(ffReadDistance(pos + ivec3(0, 0, 1))) - float(ffReadDistance(pos + ivec3(0, 0, -1)));
    vec3 grad = vec3(dx, dy, dz);
    float len = length(grad);
    if (len < 0.001) return vec3(0.0);
    return -grad / len; // negate: move downhill toward target
}

// ---- Terrain helpers ----

bool isSolidAt(ivec3 gp) {
    if (!isValidPos(gp)) return true; // out of bounds = solid wall
    uint vi = posToIndex(gp);
    Voxel v = getPreviousVoxel(vi);
    return !isVoxelAir(v) && !isVoxelType(v, VOXEL_TYPE_WATER) && !isVoxelType(v, VOXEL_TYPE_DEBUG);
}

bool isGrounded(vec3 pos) {
    ivec3 below = ivec3(floor(pos + vec3(0.0, -GROUND_CHECK_DIST, 0.0)));
    return isSolidAt(below);
}

// Check all 6 face neighbors for solid contact.
// Returns a bitmask: +X=1, -X=2, +Y=4, -Y=8, +Z=16, -Z=32
uint getTouchingSolids(vec3 pos) {
    ivec3 gp = ivec3(floor(pos));
    uint mask = 0u;
    if (isSolidAt(gp + ivec3( 1, 0, 0))) mask |= 1u;
    if (isSolidAt(gp + ivec3(-1, 0, 0))) mask |= 2u;
    if (isSolidAt(gp + ivec3( 0, 1, 0))) mask |= 4u;
    if (isSolidAt(gp + ivec3( 0,-1, 0))) mask |= 8u;
    if (isSolidAt(gp + ivec3( 0, 0, 1))) mask |= 16u;
    if (isSolidAt(gp + ivec3( 0, 0,-1))) mask |= 32u;
    return mask;
}

bool isTouchingSolid(vec3 pos) {
    return getTouchingSolids(pos) != 0u;
}

// ---- Main ----

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
void main() {
    uint entity_id = gl_GlobalInvocationID.x;
    uint active_count = entityBuffer.data[0];
    if (entity_id >= active_count) return;

    vec3 pos = getEntityPosition(entity_id);
    vec3 vel = getEntityVelocity(entity_id);
    vec3 accel = vec3(0.0);

    // 1. Flow field force: follow gradient toward target
    uint myDist = ffReadDistance(ivec3(floor(pos)));
    if (myDist > 0u && myDist < 0xFFFFu) {
        accel += computeFlowGradient(pos) * FLOW_WEIGHT;
    }

    // 2. Boid forces: separation + cohesion (O(N^2) loop)
    vec3 separation = vec3(0.0);
    vec3 cohesionCenter = vec3(0.0);
    uint cohesionCount = 0u;

    for (uint i = 0u; i < active_count; i++) {
        if (i == entity_id) continue;
        vec3 other_pos = getEntityPosition(i);
        vec3 diff = pos - other_pos;
        float dist = length(diff);

        // Separation: inverse-distance repulsion at close range
        if (dist < SEPARATION_RADIUS && dist > 0.001) {
            separation += normalize(diff) / dist;
        }

        // Cohesion: accumulate center of mass of nearby entities
        if (dist < COHESION_RADIUS) {
            cohesionCenter += other_pos;
            cohesionCount++;
        }
    }

    accel += separation * SEPARATION_WEIGHT;

    if (cohesionCount > 0u) {
        cohesionCenter /= float(cohesionCount);
        vec3 toCenter = cohesionCenter - pos;
        float toCenterLen = length(toCenter);
        if (toCenterLen > 0.001) {
            accel += normalize(toCenter) * COHESION_WEIGHT;
        }
    }

    // 3. Gravity (only when not grounded)
    if (!isTouchingSolid(pos)) {
        accel.y += GRAVITY;
    } else if (vel.y < 0.0) {
        vel.y = 0.0; // stop downward velocity when grounded
    }

    // 4. Integrate velocity and position
    vel += accel * DT;
    vel *= DAMPING;

    // Clamp speed
    float speed = length(vel);
    if (speed > MAX_SPEED) {
        vel = vel / speed * MAX_SPEED;
    }

    vec3 new_pos = pos + vel * DT;

    // 5. Per-axis terrain collision (sliding)
    // Check X axis
    if (isSolidAt(ivec3(floor(vec3(new_pos.x, pos.y, pos.z))))) {
        new_pos.x = pos.x;
        vel.x = 0.0;
    }
    // Check Y axis
    if (isSolidAt(ivec3(floor(vec3(new_pos.x, new_pos.y, pos.z))))) {
        new_pos.y = pos.y;
        vel.y = 0.0;
    }
    // Check Z axis
    if (isSolidAt(ivec3(floor(vec3(new_pos.x, new_pos.y, new_pos.z))))) {
        new_pos.z = pos.z;
        vel.z = 0.0;
    }

    // 6. Pop out of terrain if spawned inside solid
    if (isSolidAt(ivec3(floor(new_pos)))) {
        new_pos.y += 1.0;
        vel = vec3(0.0);
    }

    // 7. Bounds clamping
    vec3 grid_max = vec3(voxelWorldProperties.grid_size.xyz) - vec3(1.0);
    new_pos = clamp(new_pos, vec3(0.5), grid_max - vec3(0.5));

    // 8. Write back
    setEntityPosition(entity_id, new_pos);
    setEntityVelocity(entity_id, vel);
}
