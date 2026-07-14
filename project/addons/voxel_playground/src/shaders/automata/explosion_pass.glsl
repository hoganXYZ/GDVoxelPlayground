#[compute]
#version 460

// Explosion pass (FallingSandJava Explosion.enact, adapted to the GPU).
// Runs before the movement pass on the same buffer flip, so it edits the
// PREVIOUS buffer that movement is about to read. Every thread writes only
// its own cell — instead of Java's serial center-out rays with a shared
// visited cache, each affected voxel marches from itself back toward the
// blast center to test occlusion (a resisting cell shadows what's behind it).
//
// Zones (localRadius = radius +/- 1 per voxel for ragged edges):
//   dist <  localRadius/2                      destroy: element.explode() —
//                                              ER < strength => 70% spark /
//                                              30% air; resisted => darken+heat
//   dist <  localRadius/2 + max(localRadius/4, 1)
//                                              throw: powders/liquids become
//                                              ballistic particles with outward
//                                              velocity dir * radius * 4/3
//                                              quanta (Java dir * radius * 5)

#include "../utility.glsl.inc"
#include "../voxel_world.glsl.inc"
#include "../voxel_elements.glsl.inc"

layout(std430, set = 1, binding = 15) restrict readonly buffer ExplosionQueue {
    uint explosion_count;
    uint spark_element_id; // 0 = sparks disabled
    uint _eq_pad0;
    uint _eq_pad1;
    // pairs: [i*2] = xyz center (grid space), w radius; [i*2+1] = x strength
    vec4 explosion_data[32];
};

// scale the packed color's brightness (Java's darkenColorByMatrix)
Voxel darkenVoxel(Voxel v, float factor) {
    vec3 c = decompress_color16((v.data >> 8) & 0xFFFFu);
    c *= clamp(factor, 0.25, 1.0);
    v.data = (v.data & 0xFF0000FFu) | ((compress_color16(c) & 0xFFFFu) << 8);
    return v;
}

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
void main() {
    ivec3 pos = ivec3(gl_GlobalInvocationID.xyz);
    if (!isValidPos(pos)) return;
    uint count = min(explosion_count, 16u);
    if (count == 0u) return;

    uint voxel_index = posToIndex(pos);

    for (uint e = 0u; e < count; e++) {
        vec3 center = explosion_data[e * 2u].xyz;
        float radius = explosion_data[e * 2u].w;
        float strength = explosion_data[e * 2u + 1u].x;

        float local_radius = radius + (((cellRoll10k(pos, 601u + e) & 1u) == 0u) ? 1.0 : -1.0);
        vec3 to_center = center - (vec3(pos) + 0.5);
        float dist = length(to_center);
        float inner_edge = local_radius * 0.5;
        float outer_edge = inner_edge + max(local_radius * 0.25, 1.0);
        if (dist >= outer_edge)
            continue;

        Voxel v = getPreviousVoxel(voxel_index);
        uint type = getVoxelType(v);
        ElementDef def = elementDefs[type];
        bool is_air = isVoxelAir(v);
        bool was_static = !is_air && (def.flags & ELEMENT_FLAG_DYNAMIC) == 0u;

        // ---- occlusion march toward the center through the prev buffer ----
        bool blocked = false;
        if (dist > 1.0) {
            vec3 origin = vec3(pos) + 0.5;
            vec3 dirn = to_center / dist;
            for (float t = 1.0; t < dist - 0.5 && !blocked; t += 0.7) {
                ivec3 c = ivec3(floor(origin + dirn * t));
                if (c == pos || !isValidPos(c))
                    continue;
                Voxel cv = getPreviousVoxel(posToIndex(c));
                if (!isVoxelAir(cv) &&
                    elementDefs[getVoxelType(cv)].explosion_resistance >= strength)
                    blocked = true;
            }
        }

        if (blocked) {
            // shadowed: scorch only (Java's onlyDarken path)
            if (!is_air) {
                Voxel darker = darkenVoxel(v, dist / max(local_radius, 1.0));
                if (was_static) setBothVoxelBuffers(voxel_index, darker);
                else            setPreviousVoxel(voxel_index, darker);
            }
            break;
        }

        if (dist < inner_edge) {
            // ---- destroy zone ----
            if (is_air) {
                if (spark_element_id != 0u && cellRoll10k(pos, 631u + e) < 5000u) {
                    setPreviousVoxel(voxel_index, createElementVoxel(spark_element_id, pos));
                    setPreviousAux(voxel_index, defaultAuxFor(spark_element_id));
                    setPreviousDynamics(voxel_index, DYN_FREEFALLING);
                }
            } else if (def.explosion_resistance < strength) {
                // destroyed: 70% flash to a spark, else clean air (Element.explode)
                bool spark = spark_element_id != 0u && cellRoll10k(pos, 641u + e) < 7000u;
                Voxel product = spark ? createElementVoxel(spark_element_id, pos) : createAirVoxel();
                setPreviousVoxel(voxel_index, product);
                setPreviousAux(voxel_index, spark ? defaultAuxFor(spark_element_id) : 0u);
                setPreviousDynamics(voxel_index, spark ? DYN_FREEFALLING : 0u);
                if (was_static)
                    setVoxel(voxel_index, createAirVoxel()); // else the current-buffer copy resurrects
            } else {
                // resisted: scorch and heat (Java receiveHeat(300) + darken)
                Voxel darker = darkenVoxel(v, dist / max(local_radius, 1.0));
                if (was_static) setBothVoxelBuffers(voxel_index, darker);
                else            setPreviousVoxel(voxel_index, darker);
                uint aux = getPreviousAux(voxel_index);
                setPreviousAux(voxel_index, auxSetTempQ(aux, auxGetTempQ(aux) + 1600u));
            }
        } else {
            // ---- throw ring ----
            if (is_air) {
                if (spark_element_id != 0u && cellRoll10k(pos, 651u + e) < 3000u) {
                    setPreviousVoxel(voxel_index, createElementVoxel(spark_element_id, pos));
                    setPreviousAux(voxel_index, defaultAuxFor(spark_element_id));
                    setPreviousDynamics(voxel_index, DYN_FREEFALLING);
                }
            } else {
                Voxel darker = darkenVoxel(v, dist / max(local_radius, 1.0));
                uint aux = getPreviousAux(voxel_index);
                if (def.movement_class == MOVE_POWDER || def.movement_class == MOVE_LIQUID) {
                    // becomes a ballistic particle flying away from the blast
                    vec3 dir = -to_center / max(dist, 0.001);
                    ivec3 throw_vel = ivec3(round(dir * radius * 1.33));
                    setPreviousVoxel(voxel_index, darker);
                    setPreviousDynamics(voxel_index,
                                        packDyn(throw_vel, DYN_PARTICLE | DYN_FREEFALLING));
                } else {
                    if (was_static) setBothVoxelBuffers(voxel_index, darker);
                    else            setPreviousVoxel(voxel_index, darker);
                }
                setPreviousAux(voxel_index, auxSetTempQ(aux, auxGetTempQ(aux) + 1600u));
            }
        }
        break; // first applicable explosion wins for this voxel
    }
}
