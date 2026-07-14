#[compute]
#version 460

// Generic, element-table-driven movement pass. Replaces the hardcoded
// water/sand logic in liquid.glsl. See docs/runtime_ca_design.md.
//
// Runs twice per tick as a checkerboard: sub_pass 0 processes cells where
// (x+y+z+frame)&1 == 0, sub_pass 1 the rest. Face-adjacent cells never act in
// the same sub-pass, which makes content-taking (swaps, displacement) safe:
//  - moving into air: CAS 0 -> me on the current buffer (erased cells are 0)
//  - taking a fluid: CAS-reserve its cell in the current buffer, then
//    CAS-take its content out of the *previous* buffer so its own thread
//    (running in the other sub-pass) sees it is gone and does nothing.
//  - a voxel that already acted persists itself into the current buffer,
//    which makes any later CAS 0 -> x reservation of its cell fail.

#include "../utility.glsl.inc"
#include "../voxel_world.glsl.inc"
#include "../voxel_elements.glsl.inc"

layout(push_constant) uniform Params {
    uint sub_pass;
    uint _pad0;
    uint _pad1;
    uint _pad2;
} params;

const ivec3 DOWN = ivec3(0, -1, 0);
const ivec3 UP = ivec3(0, 1, 0);
ivec3 lateral_dirs[4] = ivec3[](
    ivec3(-1, 0, 0),
    ivec3(0, 0, 1),
    ivec3(1, 0, 0),
    ivec3(0, 0, -1)
);

// liquid direction memory lives in the low 4 bits of the voxel word
uint getVoxelDirectionID(Voxel voxel) { return voxel.data & 0xFu; }
void setVoxelDirectionID(inout Voxel voxel, uint directionID) {
    voxel.data = (voxel.data & ~0xFu) | (directionID & 0xFu);
}

const uint MOVE_FAIL = 0u;
const uint MOVE_OK   = 1u;
const uint MOVE_VOID = 2u;

// Attempt to move voxel v (with aux + dynamics) from from_pos into to_pos.
// allow_fluid_swap permits displacing a liquid/gas when densities favor it;
// swaps are only attempted for straight vertical moves (guaranteed to be in
// the other checkerboard sub-pass). Moves into air are safe in any direction.
uint tryMove(uint from_index, ivec3 from_pos, ivec3 to_pos, Voxel v, uint aux, uint dyn,
             float my_density, bool allow_fluid_swap, uint salt) {
    if (!isValidPos(to_pos)) {
        // fell out of the world: void borders, matches previous behavior
        setPreviousVoxel(from_index, createAirVoxel());
        return MOVE_VOID;
    }
    uint to_index = posToIndex(to_pos);
    Voxel target = getPreviousVoxel(to_index);

    if (isVoxelAir(target)) {
        if (casVoxelCurrent(to_index, 0u, v.data) != 0u)
            return MOVE_FAIL; // someone claimed it first
        setAux(to_index, aux);
        atomicOrCurrentDynamics(to_index, dyn);
        setPreviousVoxel(from_index, createAirVoxel());
        return MOVE_OK;
    }

    if (!allow_fluid_swap)
        return MOVE_FAIL;

    ivec3 d = to_pos - from_pos;
    if (d.x != 0 || d.z != 0)
        return MOVE_FAIL; // swaps only vertically (other sub-pass guaranteed)

    ElementDef tdef = elementDefs[getVoxelType(target)];
    if (tdef.movement_class != MOVE_LIQUID && tdef.movement_class != MOVE_GAS)
        return MOVE_FAIL;

    bool favorable = (d.y < 0 && tdef.density < my_density) ||
                     (d.y > 0 && tdef.density > my_density);
    if (!favorable)
        return MOVE_FAIL;

    float p = abs(my_density - tdef.density) / (my_density + tdef.density);
    if (float(pairRoll10k(from_pos, to_pos, salt)) >= p * 10000.0)
        return MOVE_FAIL;

    // reserve the destination cell, then take its content
    if (casVoxelCurrent(to_index, 0u, v.data) != 0u)
        return MOVE_FAIL;
    if (casVoxelPrevious(to_index, target.data, 0u) != target.data) {
        // target already acted (moved away); undo the reservation
        casVoxelCurrent(to_index, v.data, 0u);
        return MOVE_FAIL;
    }
    uint displaced_aux = getPreviousAux(to_index);
    uint displaced_dyn = getPreviousDynamics(to_index);
    setAux(to_index, aux);
    atomicOrCurrentDynamics(to_index, dyn);
    // deposit the displaced fluid in our cell (CAS so we can never clobber a
    // concurrent diagonal claim of our freshly vacated cell)
    if (casVoxelCurrent(from_index, 0u, target.data) == 0u) {
        setAux(from_index, displaced_aux);
        atomicOrCurrentDynamics(from_index, displaced_dyn);
    }
    setPreviousVoxel(from_index, createAirVoxel());
    return MOVE_OK;
}

void persist(uint index, Voxel v, uint aux, uint dyn) {
    setVoxel(index, v);
    setAux(index, aux);
    // OR, not a plain store: lateral neighbors may concurrently set DYN_WOKEN
    // on this cell, and the current dynamics buffer is all-zero at pass start
    atomicOrCurrentDynamics(index, dyn);
}

// Multi-cell movement along the velocity stored in dyn (FallingSandJava's
// Bresenham path walk, MovableSolid.step). Velocity quanta are 1/16 cell per
// tick; whole quanta become path cells, the remainder moves one extra cell
// probabilistically (no stored sub-cell accumulator). The path is walked
// through the PREV buffer to the furthest air cell before the first blocker,
// then that single origin->destination move is claimed with tryMove (air-only,
// parity-agnostic); on a lost claim race we retry one cell nearer. Fluid swaps
// are never attempted here — sinking through liquids stays a single-step,
// straight-vertical move so the checkerboard swap invariant holds.
uint moveAlongVelocity(uint index, ivec3 pos, Voxel v, uint aux, uint dyn, ElementDef def, uint salt) {
    ivec3 vel = dynVel(dyn);
    ivec3 av = abs(vel);
    ivec3 sgn = ivec3(sign(vel));
    ivec3 steps = av >> 4;
    steps.x += cellRoll10k(pos, salt + 100u) < uint(av.x & 15) * 625u ? 1 : 0;
    steps.y += cellRoll10k(pos, salt + 200u) < uint(av.y & 15) * 625u ? 1 : 0;
    steps.z += cellRoll10k(pos, salt + 300u) < uint(av.z & 15) * 625u ? 1 : 0;

    int upper = min(max(steps.x, max(steps.y, steps.z)), 8);
    if (upper <= 0)
        return MOVE_FAIL;

    // every axis advances floor(i * slope); the dominant axis' slope is exactly
    // 1 so it steps every iteration (Java: (min+1)/(upperBound+1))
    vec3 slope = vec3(steps + 1) / float(upper + 1);

    int last_i = 0;
    for (int i = 1; i <= upper; i++) {
        ivec3 off = min(ivec3(vec3(float(i)) * slope), steps);
        ivec3 cell = pos + sgn * off;
        if (!isValidPos(cell)) {
            // path leaves the world: void the voxel (matches tryMove borders)
            setPreviousVoxel(index, createAirVoxel());
            return MOVE_VOID;
        }
        if (!isVoxelAir(getPreviousVoxel(posToIndex(cell))))
            break;
        last_i = i;
    }

    for (int i = last_i; i >= 1; i--) {
        ivec3 off = min(ivec3(vec3(float(i)) * slope), steps);
        uint r = tryMove(index, pos, pos + sgn * off, v, aux, dyn, def.density, false, salt);
        if (r != MOVE_FAIL)
            return r;
    }
    return MOVE_FAIL;
}

// -------------------------------------- MOVEMENT CLASSES --------------------------------------

// A moving grain wakes the powders beside its origin (FallingSandJava's
// setAdjacentNeighborsFreeFalling): single-bit atomicOr into their current
// dynamics word — the only cross-cell dynamics write that is always safe.
// The woken cell rolls against its inertial_resistance next tick.
void wakePowderNeighbors(ivec3 pos) {
    for (uint i = 0u; i < 4u; i++) {
        ivec3 np = pos + lateral_dirs[i];
        if (!isValidPos(np)) continue;
        uint nindex = posToIndex(np);
        Voxel nv = getPreviousVoxel(nindex);
        if (isVoxelAir(nv)) continue;
        if (elementDefs[getVoxelType(nv)].movement_class != MOVE_POWDER) continue;
        atomicOrCurrentDynamics(nindex, DYN_WOKEN);
    }
}

// Ballistic particle flight (FallingSandJava Particle.step): a voxel flagged
// DYN_PARTICLE keeps its real element type but ignores its normal movement
// rules — it flies along its velocity through air only, and converts back to
// a normal element the moment it is fully blocked (Java's moveToLastValid +
// dieAndReplace(containedElementType); keeping the type byte makes the
// "contained element" storage and rendering free). Residual velocity and the
// freefall flag are kept so powders slide realistically on touchdown.
void moveParticle(uint index, ivec3 pos, Voxel v, uint aux, uint dyn, ElementDef def) {
    ivec3 vel = dynVel(dyn);
    // Java: if (vel.y > -64 && vel.y < 32) vel.y = -64  (quanta: -17 / 9)
    if (vel.y > -17 && vel.y < 9)
        vel.y = -17;
    vel.y -= 1 + (cellRoll10k(pos, 67u) < 3333u ? 1 : 0);
    vel = clamp(vel, ivec3(-127), ivec3(127));

    uint fly_dyn = packDyn(vel, DYN_PARTICLE | DYN_FREEFALLING);
    uint r = moveAlongVelocity(index, pos, v, aux, fly_dyn, def, 61u);
    if (r != MOVE_FAIL) return;

    // fully blocked: land and become a normal element again
    persist(index, v, aux, packDyn(vel, DYN_FREEFALLING));
}

void movePowder(uint index, ivec3 pos, Voxel v, uint aux, uint dyn, ElementDef def) {
    ivec3 vel = dynVel(dyn);
    uint flags = dynFlags(dyn);

    // a neighbor moved past last tick: roll against inertial resistance to
    // start moving (Java: isFreeFalling = random > inertialResistance)
    if ((flags & DYN_WOKEN) != 0u) {
        flags &= ~DYN_WOKEN;
        if (float(cellRoll10k(pos, 41u)) >= def.inertial_resistance * 10000.0)
            flags |= DYN_FREEFALLING;
    }

    // integrate gravity: Java adds 5/frame in 1/60-cell units ≈ 1.33 quanta
    // per tick — apply -1 always plus an extra -1 a third of the time
    vel.y -= 1 + (cellRoll10k(pos, 31u) < 3333u ? 1 : 0);
    vel.y = max(vel.y, -127);
    // air friction bleeds lateral speed while freefalling (Java: vel.x *= 0.9)
    if ((flags & DYN_FREEFALLING) != 0u) {
        vel.x = (vel.x * 29) / 32;
        vel.z = (vel.z * 29) / 32;
    }

    // straight fall happens regardless of the freefall flag (a settled grain
    // whose support vanished must drop); moving means freefalling
    uint fall_dyn = packDyn(vel, flags | DYN_FREEFALLING);
    uint r = moveAlongVelocity(index, pos, v, aux, fall_dyn, def, 37u);
    if (r != MOVE_FAIL) { wakePowderNeighbors(pos); return; }

    // blocked: single-step density swap straight down (sink into liquid)
    r = tryMove(index, pos, pos + DOWN, v, aux, fall_dyn, def.density, true, 3u);
    if (r != MOVE_FAIL) { wakePowderNeighbors(pos); return; }

    if ((flags & DYN_FREEFALLING) == 0u) {
        // settled grains do not slide — this is what keeps piles asleep
        persist(index, v, aux, packDyn(ivec3(vel.x, -33, vel.z), flags));
        return;
    }

    // ---- freefalling landing (Java MovableSolid.actOnNeighboringElement) ----
    // convert fall speed into a lateral push: Java vel.x = ±max(|vel.y|/31, 105)
    // (105 java units = 28 quanta), along the existing lean, else random
    int lat = max(-vel.y / 31, 28);
    if (vel.x == 0 && vel.z == 0) {
        ivec3 rdir = lateral_dirs[cellRoll10k(pos, 43u) % 4u];
        vel.x = rdir.x * lat;
        vel.z = rdir.z * lat;
    } else if (abs(vel.x) >= abs(vel.z)) {
        vel.x = vel.x < 0 ? -lat : lat;
        vel.z = 0;
    } else {
        vel.z = vel.z < 0 ? -lat : lat;
        vel.x = 0;
    }
    vel.y = -33; // Java resets landed fall speed to -124 (-33 quanta)

    // ground friction against the support element below
    ElementDef sdef = elementDefs[getVoxelType(getPreviousVoxel(posToIndex(pos + DOWN)))];
    float fric = def.friction_factor * sdef.friction_factor;
    vel.x = int(float(vel.x) * fric);
    vel.z = int(float(vel.z) * fric);

    ivec3 slide = abs(vel.x) >= abs(vel.z) ? ivec3(sign(vel.x), 0, 0) : ivec3(0, 0, sign(vel.z));
    if (slide != ivec3(0)) {
        // diagonal-down in the slide direction keeps the grain freefalling
        r = tryMove(index, pos, pos + slide + DOWN, v, aux,
                    packDyn(vel, flags | DYN_FREEFALLING), def.density, false, 5u);
        if (r != MOVE_FAIL) { wakePowderNeighbors(pos); return; }

        // flat sideways slide brings it to rest at the new cell
        r = tryMove(index, pos, pos + slide, v, aux,
                    packDyn(vel, flags & ~DYN_FREEFALLING), def.density, false, 7u);
        if (r != MOVE_FAIL) { wakePowderNeighbors(pos); return; }

        // blocked sideways: bounce the lean the other way (Java vel.x *= -1)
        vel.x = -vel.x;
        vel.z = -vel.z;
    }

    // fully blocked: come to rest
    persist(index, v, aux, packDyn(ivec3(vel.x, -33, vel.z), flags & ~DYN_FREEFALLING));
}

void moveLiquid(uint index, ivec3 pos, Voxel v, uint aux, uint dyn, ElementDef def) {
    // gravity + multi-cell fall like powders; liquids are always "freefalling"
    // (inertial resistance does not apply, Java Liquid IR = 0)
    ivec3 vel = dynVel(dyn);
    vel.y -= 1 + (cellRoll10k(pos, 31u) < 3333u ? 1 : 0);
    vel.y = max(vel.y, -127);
    // lateral velocity bleeds faster in liquids (Java: vel.x *= 0.8)
    vel.x = (vel.x * 26) / 32;
    vel.z = (vel.z * 26) / 32;
    uint move_dyn = packDyn(vel, dynFlags(dyn) | DYN_FREEFALLING);

    uint r = moveAlongVelocity(index, pos, v, aux, move_dyn, def, 37u);
    if (r != MOVE_FAIL) return;

    // blocked: single-step density swap straight down (sink under denser fluid)
    r = tryMove(index, pos, pos + DOWN, v, aux, move_dyn, def.density, true, 7u);
    if (r != MOVE_FAIL) return;

    vel.y = -33; // landed: reset to the settled fall speed
    uint rest_dyn = packDyn(vel, dynFlags(dyn));

    // viscosity: flow is the chance per tick to attempt lateral movement
    if (float(cellRoll10k(pos, 11u)) >= def.flow * 10000.0) {
        persist(index, v, aux, rest_dyn);
        return;
    }

    // lateral flow with direction memory (matches previous liquid behavior)
    uvec4 random_value = hash(uvec4(uvec3(pos), voxelWorldProperties.frame));
    uint randPercent = random_value.x % 100u;
    uint index_dir;
    uint previous_index = getVoxelDirectionID(v);
    if (previous_index == 0u) {
        index_dir = random_value.y % 4u;
    } else {
        previous_index--;
        if (randPercent < 80u) index_dir = previous_index;
        else if (randPercent < 90u) index_dir = (previous_index + 1u) % 4u;
        else index_dir = (previous_index + 3u) % 4u;
    }
    setVoxelDirectionID(v, index_dir + 1u);
    ivec3 dir = lateral_dirs[index_dir];

    // dispersion (Java Liquid.iterateToAdditional): walk up to `distance`
    // cells sideways through prev-buffer air, preferring the first cell with
    // air below (a drop point) so the liquid pours over edges instead of
    // creeping one cell per tick
    uint disp = max(def.dispersion_rate, 1u);
    int distance = int(cellRoll10k(pos, 53u) < 5000u ? disp + 2u : max(disp - 1u, 1u));
    distance = min(distance, 8);

    int drop_i = 0;
    int last_air = 0;
    for (int i = 1; i <= distance; i++) {
        ivec3 cell = pos + dir * i;
        if (!isValidPos(cell)) break;
        if (!isVoxelAir(getPreviousVoxel(posToIndex(cell)))) break;
        last_air = i;
        if (drop_i == 0) {
            ivec3 below = cell + DOWN;
            if (isValidPos(below) && isVoxelAir(getPreviousVoxel(posToIndex(below))))
                drop_i = i;
        }
    }

    if (drop_i > 0) {
        r = tryMove(index, pos, pos + dir * drop_i, v, aux,
                    packDyn(vel, dynFlags(dyn) | DYN_FREEFALLING), def.density, false, 13u);
        if (r != MOVE_FAIL) return;
    }
    for (int i = last_air; i >= 1; i--) {
        if (i == drop_i) continue; // already tried
        r = tryMove(index, pos, pos + dir * i, v, aux, rest_dyn, def.density, false, 13u);
        if (r != MOVE_FAIL) return;
    }
    // parity with the old single-step border rule: liquid drains off the edge
    if (last_air == 0 && !isValidPos(pos + dir)) {
        setPreviousVoxel(index, createAirVoxel());
        return;
    }

    setVoxelDirectionID(v, 0u);
    persist(index, v, aux, rest_dyn);
}

void moveGas(uint index, ivec3 pos, Voxel v, uint aux, uint dyn, ElementDef def) {
    // weighted random walk with upward bias; rises through denser fluids.
    // dispersion_rate is the number of movement attempts per tick.
    uint attempts = clamp(def.dispersion_rate, 1u, 4u);
    for (uint attempt = 0u; attempt < attempts; attempt++) {
        uint roll = cellRoll10k(pos, 23u + attempt * 41u);
        ivec3 dir;
        if (roll < 3500u) dir = UP;
        else if (roll < 8500u) dir = lateral_dirs[(roll - 3500u) / 1250u];
        else dir = DOWN;
        uint r = tryMove(index, pos, pos + dir, v, aux, dyn, def.density, dir.x == 0 && dir.z == 0, 29u + attempt);
        if (r != MOVE_FAIL) return;
    }
    persist(index, v, aux, dyn);
}

// -------------------------------------- BEHAVIOR OPS --------------------------------------

ivec3 unpackOpOffset(uint packed) {
    return ivec3(int(packed & 3u) - 1, int((packed >> 2) & 3u) - 1, int((packed >> 4) & 3u) - 1);
}

// change/delete a target cell to `product_type` (0 = delete). Static targets
// are updated in both buffers (small documented race); dynamic targets are
// taken out of the previous buffer first so their thread does not double-act.
void opChangeCell(ivec3 target_pos, Voxel tv, uint product_type) {
    uint target_index = posToIndex(target_pos);
    Voxel product = product_type == 0u ? createAirVoxel() : createElementVoxel(product_type, target_pos);
    uint target_type = getVoxelType(tv);
    if (!isTypeDynamic(target_type)) {
        if (casVoxelCurrent(target_index, tv.data, product.data) == tv.data) {
            setPreviousVoxel(target_index, product);
            if (product_type != 0u) {
                setBothAux(target_index, defaultAuxFor(product_type));
                atomicOrCurrentDynamics(target_index, defaultDynamicsFor(product_type));
            }
        }
        return;
    }
    if (casVoxelPrevious(target_index, tv.data, 0u) == tv.data) {
        // took it before its own thread acted
        if (casVoxelCurrent(target_index, 0u, product.data) == 0u && product_type != 0u) {
            setAux(target_index, defaultAuxFor(product_type));
            atomicOrCurrentDynamics(target_index, defaultDynamicsFor(product_type));
        }
    } else {
        // it may have persisted already this tick: update in place
        if (casVoxelCurrent(target_index, tv.data, product.data) == tv.data && product_type != 0u) {
            setAux(target_index, defaultAuxFor(product_type));
            atomicOrCurrentDynamics(target_index, defaultDynamicsFor(product_type));
        }
    }
}

void runBehaviorOps(uint index, ivec3 pos, Voxel v, uint aux, uint dyn, ElementDef def) {
    bool is_dynamic = (def.flags & ELEMENT_FLAG_DYNAMIC) != 0u;

    // sweep 1: support veto
    bool vetoed = false;
    for (uint i = 0u; i < def.behavior_count; i++) {
        BehaviorOp op = behaviorOps[def.behavior_offset + i];
        if (op.opcode != OP_SUPPORT) continue;
        ivec3 tp = pos + unpackOpOffset(op.packed_offset);
        if (!isValidPos(tp)) continue;
        Voxel tv = getPreviousVoxel(posToIndex(tp));
        if (isVoxelAir(tv)) continue;
        if (op.arg == ELEM_ANY || getVoxelType(tv) == op.arg)
            vetoed = true;
    }

    // sweep 2: neighborhood ops (independent of movement)
    for (uint i = 0u; i < def.behavior_count; i++) {
        BehaviorOp op = behaviorOps[def.behavior_offset + i];
        if (op.opcode != OP_CREATE && op.opcode != OP_CHANGE && op.opcode != OP_DELETE)
            continue;
        if (cellRoll10k(pos, 100u + i * 7u) >= op.chance) continue;
        ivec3 tp = pos + unpackOpOffset(op.packed_offset);
        if (!isValidPos(tp)) continue;
        uint tindex = posToIndex(tp);
        Voxel tv = getPreviousVoxel(tindex);

        if (op.opcode == OP_CREATE) {
            if (isVoxelAir(tv) && op.arg != 0u) {
                Voxel product = createElementVoxel(op.arg, tp);
                if (casVoxelCurrent(tindex, 0u, product.data) == 0u) {
                    setAux(tindex, defaultAuxFor(op.arg));
                    atomicOrCurrentDynamics(tindex, defaultDynamicsFor(op.arg));
                }
            }
        } else if (op.opcode == OP_CHANGE) {
            uint from = (op.arg >> 16) & 0xFFFFu;
            uint to = op.arg & 0xFFFFu;
            if (!isVoxelAir(tv) && (from == ELEM_ANY || getVoxelType(tv) == from) && getVoxelType(tv) != to)
                opChangeCell(tp, tv, to);
        } else { // OP_DELETE
            bool self_target = tp == pos;
            if (!isVoxelAir(tv) && (self_target || getVoxelType(tv) != getVoxelType(v)) &&
                (op.arg == ELEM_ANY || getVoxelType(tv) == op.arg)) {
                opChangeCell(tp, tv, 0u);
                if (self_target) return; // deleted ourselves; nothing left to do
            }
        }
    }

    // sweep 3: movement (swap > move1 > move2), suppressed by support
    bool moved = false;
    if (!vetoed && is_dynamic) {
        for (uint pri = 0u; pri < 3u && !moved; pri++) {
            uint opcode = pri == 0u ? OP_SWAP : (pri == 1u ? OP_MOVE1 : OP_MOVE2);
            uint start = cellRoll10k(pos, 200u + pri) % max(def.behavior_count, 1u);
            for (uint j = 0u; j < def.behavior_count && !moved; j++) {
                uint i = (start + j) % def.behavior_count;
                BehaviorOp op = behaviorOps[def.behavior_offset + i];
                if (op.opcode != opcode) continue;
                if (cellRoll10k(pos, 300u + i * 13u) >= op.chance) continue;
                ivec3 tp = pos + unpackOpOffset(op.packed_offset);
                if (!isValidPos(tp)) continue;
                uint tindex = posToIndex(tp);
                Voxel tv = getPreviousVoxel(tindex);

                if (opcode == OP_SWAP && !isVoxelAir(tv)) {
                    if (op.arg != ELEM_ANY && getVoxelType(tv) != op.arg) continue;
                    if (!isTypeDynamic(getVoxelType(tv))) continue;
                    ivec3 d = tp - pos;
                    if ((abs(d.x) + abs(d.y) + abs(d.z)) != 1) continue; // face-adjacent only
                    if (casVoxelCurrent(tindex, 0u, v.data) != 0u) continue;
                    if (casVoxelPrevious(tindex, tv.data, 0u) != tv.data) {
                        casVoxelCurrent(tindex, v.data, 0u);
                        continue;
                    }
                    uint displaced_aux = getPreviousAux(tindex);
                    uint displaced_dyn = getPreviousDynamics(tindex);
                    setAux(tindex, aux);
                    atomicOrCurrentDynamics(tindex, dyn);
                    if (casVoxelCurrent(index, 0u, tv.data) == 0u) {
                        setAux(index, displaced_aux);
                        atomicOrCurrentDynamics(index, displaced_dyn);
                    }
                    setPreviousVoxel(index, createAirVoxel());
                    moved = true;
                } else if (opcode != OP_SWAP && isVoxelAir(tv)) {
                    if (casVoxelCurrent(tindex, 0u, v.data) == 0u) {
                        setAux(tindex, aux);
                        atomicOrCurrentDynamics(tindex, dyn);
                        setPreviousVoxel(index, createAirVoxel());
                        moved = true;
                    }
                }
            }
        }
    }

    if (!moved) {
        if (is_dynamic)
            persist(index, v, aux, dyn);
        else
            setAux(index, aux); // statics live in both voxel buffers already
    }
}

// -------------------------------------- MAIN --------------------------------------

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
void main() {
    ivec3 pos = ivec3(gl_GlobalInvocationID.xyz);
    if (!isValidPos(pos)) return;
    if (((uint(pos.x + pos.y + pos.z) + uint(voxelWorldProperties.frame)) & 1u) != params.sub_pass)
        return;

    uint voxel_index = posToIndex(pos);
    Voxel v = getPreviousVoxel(voxel_index);
    if (isVoxelAir(v)) return;

    uint type = getVoxelType(v);
    ElementDef def = elementDefs[type];
    uint aux = getPreviousAux(voxel_index);
    uint dyn = getPreviousDynamics(voxel_index);

    // Freshly generated/painted dynamics exist in BOTH buffers (edits write
    // both); clear our stale current-buffer copy so a move does not leave a
    // duplicate behind. CAS on our own exact data never disturbs claims.
    if ((def.flags & ELEMENT_FLAG_DYNAMIC) != 0u)
        casVoxelCurrent(voxel_index, v.data, 0u);

    // ballistic particles override every normal rule while in flight
    if ((dynFlags(dyn) & DYN_PARTICLE) != 0u && (def.flags & ELEMENT_FLAG_DYNAMIC) != 0u) {
        moveParticle(voxel_index, pos, v, aux, dyn, def);
        return;
    }

    if (def.behavior_count > 0u) {
        // authored behavior ops replace the movement preset (Sandboxels-style)
        runBehaviorOps(voxel_index, pos, v, aux, dyn, def);
        return;
    }

    switch (def.movement_class) {
        case MOVE_POWDER: movePowder(voxel_index, pos, v, aux, dyn, def); break;
        case MOVE_LIQUID: moveLiquid(voxel_index, pos, v, aux, dyn, def); break;
        case MOVE_GAS:    moveGas(voxel_index, pos, v, aux, dyn, def); break;
        case MOVE_CUSTOM:
            // dynamic, but moved by a custom kernel (which may overwrite this)
            persist(voxel_index, v, aux, dyn);
            break;
        default:
            // STATIC: voxel data lives in both buffers; carry aux forward.
            setAux(voxel_index, aux);
            break;
    }
}
