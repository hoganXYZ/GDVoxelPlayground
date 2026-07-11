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

// Attempt to move voxel v (with aux) from from_pos into to_pos.
// allow_fluid_swap permits displacing a liquid/gas when densities favor it;
// swaps are only attempted for straight vertical moves (guaranteed to be in
// the other checkerboard sub-pass). Moves into air are safe in any direction.
uint tryMove(uint from_index, ivec3 from_pos, ivec3 to_pos, Voxel v, uint aux,
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
    setAux(to_index, aux);
    // deposit the displaced fluid in our cell (CAS so we can never clobber a
    // concurrent diagonal claim of our freshly vacated cell)
    if (casVoxelCurrent(from_index, 0u, target.data) == 0u)
        setAux(from_index, displaced_aux);
    setPreviousVoxel(from_index, createAirVoxel());
    return MOVE_OK;
}

void persist(uint index, Voxel v, uint aux) {
    setVoxel(index, v);
    setAux(index, aux);
}

// -------------------------------------- MOVEMENT CLASSES --------------------------------------

void movePowder(uint index, ivec3 pos, Voxel v, uint aux, ElementDef def) {
    uint r = tryMove(index, pos, pos + DOWN, v, aux, def.density, true, 3u);
    if (r != MOVE_FAIL) return;

    uvec4 rv = hash(uvec4(uvec3(pos), voxelWorldProperties.frame));
    ivec3 dir = lateral_dirs[rv.x % 4u] + DOWN;
    r = tryMove(index, pos, pos + dir, v, aux, def.density, false, 5u);
    if (r != MOVE_FAIL) return;

    persist(index, v, aux);
}

void moveLiquid(uint index, ivec3 pos, Voxel v, uint aux, ElementDef def) {
    uint r = tryMove(index, pos, pos + DOWN, v, aux, def.density, true, 7u);
    if (r != MOVE_FAIL) return;

    // viscosity: flow is the chance per tick to attempt lateral movement
    if (float(cellRoll10k(pos, 11u)) >= def.flow * 10000.0) {
        persist(index, v, aux);
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

    r = tryMove(index, pos, pos + lateral_dirs[index_dir], v, aux, def.density, false, 13u);
    if (r != MOVE_FAIL) return;

    setVoxelDirectionID(v, 0u);
    persist(index, v, aux);
}

void moveGas(uint index, ivec3 pos, Voxel v, uint aux, ElementDef def) {
    // weighted random walk with upward bias; rises through denser fluids
    for (uint attempt = 0u; attempt < 2u; attempt++) {
        uint roll = cellRoll10k(pos, 23u + attempt * 41u);
        ivec3 dir;
        if (roll < 3500u) dir = UP;
        else if (roll < 8500u) dir = lateral_dirs[(roll - 3500u) / 1250u];
        else dir = DOWN;
        uint r = tryMove(index, pos, pos + dir, v, aux, def.density, dir.x == 0 && dir.z == 0, 29u + attempt);
        if (r != MOVE_FAIL) return;
    }
    persist(index, v, aux);
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
            if (product_type != 0u)
                setBothAux(target_index, defaultAuxFor(product_type));
        }
        return;
    }
    if (casVoxelPrevious(target_index, tv.data, 0u) == tv.data) {
        // took it before its own thread acted
        if (casVoxelCurrent(target_index, 0u, product.data) == 0u && product_type != 0u)
            setAux(target_index, defaultAuxFor(product_type));
    } else {
        // it may have persisted already this tick: update in place
        if (casVoxelCurrent(target_index, tv.data, product.data) == tv.data && product_type != 0u)
            setAux(target_index, defaultAuxFor(product_type));
    }
}

void runBehaviorOps(uint index, ivec3 pos, Voxel v, uint aux, ElementDef def) {
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
                if (casVoxelCurrent(tindex, 0u, product.data) == 0u)
                    setAux(tindex, defaultAuxFor(op.arg));
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
                    setAux(tindex, aux);
                    if (casVoxelCurrent(index, 0u, tv.data) == 0u)
                        setAux(index, displaced_aux);
                    setPreviousVoxel(index, createAirVoxel());
                    moved = true;
                } else if (opcode != OP_SWAP && isVoxelAir(tv)) {
                    if (casVoxelCurrent(tindex, 0u, v.data) == 0u) {
                        setAux(tindex, aux);
                        setPreviousVoxel(index, createAirVoxel());
                        moved = true;
                    }
                }
            }
        }
    }

    if (!moved) {
        if (is_dynamic)
            persist(index, v, aux);
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

    // Freshly generated/painted dynamics exist in BOTH buffers (edits write
    // both); clear our stale current-buffer copy so a move does not leave a
    // duplicate behind. CAS on our own exact data never disturbs claims.
    if ((def.flags & ELEMENT_FLAG_DYNAMIC) != 0u)
        casVoxelCurrent(voxel_index, v.data, 0u);

    if (def.behavior_count > 0u) {
        // authored behavior ops replace the movement preset (Sandboxels-style)
        runBehaviorOps(voxel_index, pos, v, aux, def);
        return;
    }

    switch (def.movement_class) {
        case MOVE_POWDER: movePowder(voxel_index, pos, v, aux, def); break;
        case MOVE_LIQUID: moveLiquid(voxel_index, pos, v, aux, def); break;
        case MOVE_GAS:    moveGas(voxel_index, pos, v, aux, def); break;
        case MOVE_CUSTOM:
            // dynamic, but moved by a custom kernel (which may overwrite this)
            persist(voxel_index, v, aux);
            break;
        default:
            // STATIC: voxel data lives in both buffers; carry aux forward.
            setAux(voxel_index, aux);
            break;
    }
}
