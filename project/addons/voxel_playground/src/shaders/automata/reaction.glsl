#[compute]
#version 460

// Reaction + thermal pass. Runs on its own buffer flip (the C++ side
// increments the frame counter between the movement pass and this pass), so
// it reads a complete, stable snapshot of the post-movement world and every
// thread writes only its own cell. Pair-symmetric RNG makes both sides of a
// reacting pair agree on whether a reaction fired. Replaces freeze_lava.glsl.
//
// Per voxel, in order:
//   1. contact reactions against the 6 face neighbors (first match wins)
//   2. heat diffusion through the aux temperature channel
//   3. life decay (fire burns out, steam condenses, ...)
//   4. phase transitions (temp_high/state_high, temp_low/state_low)

#include "../utility.glsl.inc"
#include "../voxel_world.glsl.inc"
#include "../voxel_elements.glsl.inc"

const ivec3 neighbor_dirs[6] = ivec3[](
    ivec3(-1, 0, 0), ivec3(1, 0, 0),
    ivec3(0, -1, 0), ivec3(0, 1, 0),
    ivec3(0, 0, -1), ivec3(0, 0, 1)
);

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
void main() {
    ivec3 pos = ivec3(gl_GlobalInvocationID.xyz);
    if (!isValidPos(pos)) return;

    uint voxel_index = posToIndex(pos);
    Voxel v = getPreviousVoxel(voxel_index);
    uint type = getVoxelType(v);
    ElementDef def = elementDefs[type];

    bool is_air = isVoxelAir(v);
    if (is_air && def.reaction_count == 0u)
        return; // air only participates if it has authored rules (e.g. condensation)

    uint aux = is_air ? defaultAuxFor(0u) : getPreviousAux(voxel_index);

    // ballistic particles ignore reactions/heat/life while in flight
    // (Java Particle disables receiveHeat and never reacts)
    if (!is_air && isTypeDynamic(type)) {
        uint dyn = getPreviousDynamics(voxel_index);
        if ((dynFlags(dyn) & DYN_PARTICLE) != 0u) {
            setVoxel(voxel_index, v);
            setAux(voxel_index, aux);
            setDynamics(voxel_index, dyn);
            return;
        }
    }

    uint temp_q = auxGetTempQ(aux);
    uint new_type = type;
    bool fired = false;

    // ---- 1. contact reactions ----
    for (uint d = 0u; d < 6u && !fired; d++) {
        ivec3 np = pos + neighbor_dirs[d];
        if (!isValidPos(np)) continue;
        uint nindex = posToIndex(np);
        Voxel nv = getPreviousVoxel(nindex);
        uint ntype = getVoxelType(nv);
        if (is_air && ntype == 0u) continue;

        for (uint r = 0u; r < def.reaction_count; r++) {
            ReactionRule rule = reactionRules[def.reaction_offset + r];
            if (rule.partner != ntype) continue;

            // temperature gates; mirror rules test the partner so both sides
            // of a pair evaluate the same cell's temperature
            uint gate_temp;
            if ((rule.flags & REACTION_GATE_ON_PARTNER) != 0u)
                gate_temp = ntype == 0u ? auxGetTempQ(defaultAuxFor(0u)) : auxGetTempQ(getPreviousAux(nindex));
            else
                gate_temp = temp_q;
            if (rule.temp_min_q != TEMP_NONE_LOW && gate_temp < rule.temp_min_q) continue;
            if (rule.temp_max_q != TEMP_NONE_HIGH && gate_temp > rule.temp_max_q) continue;

            if (pairRoll10k(pos, np, 17u) >= rule.chance) continue;

            if (rule.self_becomes != ELEM_KEEP)
                new_type = rule.self_becomes;
            temp_q = uint(clamp(int(temp_q) + rule.temp_delta_q, 0, 0xFFFF));
            fired = true;
            break;
        }
    }

    if (is_air && !fired)
        return;

    // ---- 2. heat diffusion (air acts as an ambient-temperature sink) ----
    if (!is_air && def.heat_conduct > 0.0) {
        float T = float(temp_q);
        float dT = 0.0;
        for (uint d = 0u; d < 6u; d++) {
            ivec3 np = pos + neighbor_dirs[d];
            if (!isValidPos(np)) continue;
            uint nindex = posToIndex(np);
            uint ntype = getVoxelType(getPreviousVoxel(nindex));
            float nT = ntype == 0u ? float(elementDefs[0].initial_temp_q)
                                   : float(auxGetTempQ(getPreviousAux(nindex)));
            float k = min(def.heat_conduct, elementDefs[ntype].heat_conduct);
            dT += k * (nT - T);
        }
        T += dT / 6.0;
        temp_q = uint(clamp(T, 0.0, 65535.0));
    }

    // ---- 3. life decay ----
    uint life = auxGetLife(aux);
    if (!fired && !is_air && def.life_init > 0u) {
        if (life > 0u) life--;
        if (life == 0u) {
            new_type = def.life_into;
            fired = true;
        }
    }

    // ---- 4. phase transitions ----
    if (!fired && !is_air) {
        if (def.temp_high_q != TEMP_NONE_HIGH && temp_q >= def.temp_high_q)
            new_type = def.state_high;
        else if (def.temp_low_q != TEMP_NONE_LOW && temp_q <= def.temp_low_q)
            new_type = def.state_low;
    }

    // ---- commit (own cell only) ----
    if (new_type != type) {
        bool was_static = !is_air && !isTypeDynamic(type);
        Voxel product = new_type == 0u ? createAirVoxel() : createElementVoxel(new_type, pos);
        uint new_aux = makeAux(temp_q, elementDefs[new_type].life_init);
        bool now_static = new_type != 0u && !isTypeDynamic(new_type);

        if (now_static) {
            // statics must exist in both buffers (same as freeze_lava did)
            setBothVoxelBuffers(voxel_index, product);
            setBothAux(voxel_index, new_aux);
        } else if (was_static) {
            // static became dynamic/air: remove the previous-buffer copy so it
            // does not resurrect on the next flip
            setVoxel(voxel_index, product);
            setPreviousVoxel(voxel_index, createAirVoxel());
            setAux(voxel_index, new_aux);
        } else {
            setVoxel(voxel_index, product);
            setAux(voxel_index, new_aux);
        }
        // transformation products start with fresh dynamics (awake, spawn velocity)
        setDynamics(voxel_index, defaultDynamicsFor(new_type));
    } else {
        // unchanged: this pass owns the flip, so voxel data, aux and dynamics
        // must all be carried forward
        if (isTypeDynamic(type)) {
            setVoxel(voxel_index, v);
            setDynamics(voxel_index, getPreviousDynamics(voxel_index));
        }
        setAux(voxel_index, auxSetLife(auxSetTempQ(aux, temp_q), life));
    }
}
