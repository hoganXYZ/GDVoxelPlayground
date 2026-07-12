#[compute]
#version 460

#include "../utility.glsl.inc"
#include "../voxel_world.glsl.inc"
#include "../voxel_elements.glsl.inc"

layout(std430, set = 1, binding = 0) restrict buffer Params {
    vec4 camera_origin;
    vec4 camera_direction;
    vec4 hit_position;
    float near;
    float far;
    float radius;
    uint value;
} params;

// Smoothing = one step of mean-curvature flow on the solid/air interface:
// blur the occupancy field with a spherical kernel, then re-threshold at 0.5.
// The kernel radius scales with brush size so a large brush levels large
// features, not just single-voxel bumps.
const int MAX_KERNEL_RADIUS = 4;

bool sampleOccupied(ivec3 p, out Voxel voxel) {
    // Border-replicate so world edges read as a continuation of themselves
    // instead of as air (which would erode the map boundary).
    p = clamp(p, ivec3(0), voxelWorldProperties.grid_size.xyz - 1);
    voxel = getVoxel(posToIndex(p));
    return !isVoxelAir(voxel);
}

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
void main() {
    ivec3 pos = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 world_pos = ivec3(params.hit_position.xyz) + pos - ivec3(params.radius);
    if (!isValidPos(world_pos) || params.hit_position.w < 0) return;

    vec3 center = params.hit_position.xyz;
    float d = length(vec3(world_pos) - center);
    if (d >= params.radius) return;

    uint voxel_index = posToIndex(world_pos);
    Voxel center_voxel = getVoxel(voxel_index);
    bool center_is_air = isVoxelAir(center_voxel);
    if (isVoxelEntity(center_voxel)) return;

    // --- Gate: only the interface shell may change ---
    // Voxels whose full 3x3x3 neighborhood is uniform are deep inside solid or
    // air. Skipping them protects the interior of thin walls/floors and lets
    // the vast majority of threads exit before the wide kernel below.
    int inner_solid = 0;
    vec3 color_sum = vec3(0.0);
    float color_weight = 0.0;
    uint type_counts[8] = uint[](0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u);

    for (int x = -1; x <= 1; x++)
    for (int y = -1; y <= 1; y++)
    for (int z = -1; z <= 1; z++) {
        Voxel v;
        if (!sampleOccupied(world_pos + ivec3(x, y, z), v)) continue;
        inner_solid++;

        uint type = getVoxelType(v);
        if (type == VOXEL_TYPE_ENTITY || type == VOXEL_TYPE_DEBUG || type >= 8u) continue;
        type_counts[type]++;
        color_sum += getVoxelColor(v, world_pos + ivec3(x, y, z));
        color_weight += 1.0;
    }

    if (inner_solid == 0 || inner_solid == 27) return;

    // --- Weighted occupancy density over the wide kernel ---
    int kernel_radius = clamp(int(params.radius * 0.25 + 0.5), 1, MAX_KERNEL_RADIUS);
    float cutoff_sq = (float(kernel_radius) + 0.5) * (float(kernel_radius) + 0.5);

    float occupancy = 0.0;
    float total_weight = 0.0;

    for (int x = -kernel_radius; x <= kernel_radius; x++)
    for (int y = -kernel_radius; y <= kernel_radius; y++)
    for (int z = -kernel_radius; z <= kernel_radius; z++) {
        float dist_sq = float(x * x + y * y + z * z);
        float w = 1.0 - dist_sq / cutoff_sq;
        if (w <= 0.0) continue;

        Voxel v;
        if (sampleOccupied(world_pos + ivec3(x, y, z), v))
            occupancy += w;
        total_weight += w;
    }
    float density = occupancy / total_weight;

    // --- Threshold with hysteresis and rim feathering ---
    // The base margin keeps flat surfaces from flickering between fill and
    // erode; the rim term raises the bar toward the brush edge so the effect
    // fades out instead of ending in a hard sphere-shaped seam.
    float margin = 0.05 + 0.4 * smoothstep(0.6, 1.0, d / params.radius);

    if (center_is_air && density > 0.5 + margin) {
        // Fill: pick the dominant nearby material and blend its colors.
        uint dominant_type = 0u;
        uint best_count = 0u;
        for (uint t = 1u; t < 8u; t++) {
            if (type_counts[t] > best_count) {
                best_count = type_counts[t];
                dominant_type = t;
            }
        }
        if (dominant_type == 0u) return; // nothing fillable nearby (e.g. only entities)

        Voxel new_voxel = createVoxel(dominant_type, color_sum / color_weight);
        setBothVoxelBuffers(voxel_index, new_voxel);
        setBothAux(voxel_index, defaultAuxFor(dominant_type));
    } else if (!center_is_air && density < 0.5 - margin) {
        setBothVoxelBuffers(voxel_index, createAirVoxel());
        setBothAux(voxel_index, defaultAuxFor(VOXEL_TYPE_AIR));
    }
}
