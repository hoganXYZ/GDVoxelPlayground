#[compute]
#version 460

#include "../utility.glsl"
#include "../voxel_world.glsl"

// CellPond rule buffer: flat packed uint array
// Layout:
//   [0] rule_count
//   [1] total_data_uints
//   [2] activation_chance (1-4: how many out of 4 voxels activate)
//   [3] _pad
//   [4 .. 4 + rule_count*4 - 1] rule headers (4 uints each)
//   [data...] pattern entries (2 uints each) and result entries (4 uints each)
//
// Rule header (4 uints):
//   [0] pattern_count(16) | result_count(16)
//   [1] pattern_offset (uint index into rule_data)
//   [2] result_offset (uint index into rule_data)
//   [3] chance (0-100)
//
// Pattern entry (2 uints):
//   uint0: (dx+128)<<24 | (dy+128)<<16 | (dz+128)<<8 | match_mode
//   uint1: match_type<<24 | color_match<<16 | match_color(16)
//
// Result entry (4 uints):
//   uint0: (dx+128)<<24 | (dy+128)<<16 | (dz+128)<<8 | action
//   uint1: set_type<<24 | color_mode<<16 | set_color(16)
//   uint2: minL(8) | mina(8) | minb(8) | maxL(8)   (OKLab range, quantized)
//   uint3: maxa(8) | maxb(8) | padding(16)

layout(std430, set = 1, binding = 0) restrict readonly buffer CellPondRules {
    uint rule_data[];
};

// Match mode constants (must match cellpond_rule.h)
const uint MATCH_EXACT_TYPE = 0u;
const uint MATCH_ANY_SOLID = 1u;
const uint MATCH_ANY_LIQUID = 2u;
const uint MATCH_ANY_NON_AIR = 3u;
const uint MATCH_WILDCARD = 4u;
const uint MATCH_AIR_ONLY = 5u;

// Action constants
const uint ACTION_SET_TYPE_AND_COLOR = 0u;
const uint ACTION_COPY_FROM_PATTERN = 1u;
const uint ACTION_SET_AIR = 2u;
const uint ACTION_KEEP = 3u;

// Color mode constants
const uint COLOR_MODE_SOLID = 0u;
const uint COLOR_MODE_RANDOM_OKLAB = 1u;

// Decode offset from packed uint (biased by 128)
ivec3 decodeOffset(uint packed) {
    int dx = int((packed >> 24u) & 0xFFu) - 128;
    int dy = int((packed >> 16u) & 0xFFu) - 128;
    int dz = int((packed >> 8u) & 0xFFu) - 128;
    return ivec3(dx, dy, dz);
}

// Check if a voxel matches a pattern entry
bool matchesPattern(Voxel voxel, uint pattern_uint0, uint pattern_uint1) {
    uint mode = pattern_uint0 & 0xFFu;

    if (mode == MATCH_WILDCARD)
        return true;

    if (mode == MATCH_AIR_ONLY)
        return isVoxelAir(voxel);

    if (mode == MATCH_ANY_NON_AIR)
        return !isVoxelAir(voxel);

    if (mode == MATCH_ANY_SOLID)
        return isVoxelSolid(voxel);

    if (mode == MATCH_ANY_LIQUID)
        return isVoxelLiquid(voxel);

    if (mode == MATCH_EXACT_TYPE) {
        uint expected_type = (pattern_uint1 >> 24u) & 0xFFu;
        if (!isVoxelType(voxel, expected_type))
            return false;

        // Check color match mode
        uint color_match = (pattern_uint1 >> 16u) & 0xFFu;
        if (color_match == 1u) {
            // Exact color match
            uint expected_color = pattern_uint1 & 0xFFFFu;
            uint actual_color = (voxel.data >> 8u) & 0xFFFFu;
            return expected_color == actual_color;
        }
        return true; // color_match == 0 means don't care
    }

    return false;
}

// Build a voxel from a result entry (4 uints)
Voxel buildResultVoxel(uint r_uint1, uint r_uint2, uint r_uint3, ivec3 pos) {
    uint set_type = (r_uint1 >> 24u) & 0xFFu;
    uint color_mode = (r_uint1 >> 16u) & 0xFFu;

    uint packed_color;
    if (color_mode == COLOR_MODE_RANDOM_OKLAB) {
        // Decode OKLab ranges from quantized 8-bit values
        float minL = float((r_uint2 >> 24u) & 0xFFu) / 255.0;
        float mina = float((r_uint2 >> 16u) & 0xFFu) / 255.0 - 0.5;
        float minb = float((r_uint2 >> 8u) & 0xFFu) / 255.0 - 0.5;
        float maxL = float(r_uint2 & 0xFFu) / 255.0;
        float maxa = float((r_uint3 >> 24u) & 0xFFu) / 255.0 - 0.5;
        float maxb = float((r_uint3 >> 16u) & 0xFFu) / 255.0 - 0.5;

        // Random sample using position hash (stable per-position)
        uvec4 color_rng = hash(uvec4(pos, voxelWorldProperties.frame * 7u + 31u));
        vec3 t = vec3(float(color_rng.x & 0xFFFFu) / 65535.0,
                      float(color_rng.y & 0xFFFFu) / 65535.0,
                      float(color_rng.z & 0xFFFFu) / 65535.0);

        vec3 lab = vec3(mix(minL, maxL, t.x), mix(mina, maxa, t.y), mix(minb, maxb, t.z));
        vec3 rgb = oklab_to_srgb(lab);
        packed_color = compress_color16(rgb);
    } else {
        packed_color = r_uint1 & 0xFFFFu;
    }

    Voxel v;
    v.data = int((set_type << 24u) | (packed_color << 8u));
    return v;
}

// Store for matched pattern voxels (used for COPY_FROM_PATTERN)
// Max 16 pattern entries per rule
Voxel matched_voxels[16];

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
void main() {
    ivec3 pos = ivec3(gl_GlobalInvocationID.xyz);
    if (!isValidPos(pos)) return;

    uint rule_count = rule_data[0];
    if (rule_count == 0u) return;

    // Stochastic activation
    uvec4 rng = hash(uvec4(pos, voxelWorldProperties.frame));
    uint activation = rule_data[2];
    if (activation == 0u) activation = 1u;
    if ((rng.x & 3u) >= activation) return;

    // Randomize rule evaluation order to prevent priority bias
    uint start_rule = rng.y % rule_count;

    for (uint i = 0u; i < rule_count; i++) {
        uint rule_idx = (start_rule + i) % rule_count;

        // Decode rule header (4 uints per header)
        uint header_base = 4u + rule_idx * 4u;
        uint counts = rule_data[header_base];
        uint pattern_count = counts & 0xFFFFu;
        uint result_count = (counts >> 16u) & 0xFFFFu;
        uint pattern_offset = rule_data[header_base + 1u];
        uint result_offset = rule_data[header_base + 2u];
        uint chance = rule_data[header_base + 3u];

        if (pattern_count == 0u) continue;

        // Check all pattern entries
        bool matched = true;
        for (uint p = 0u; p < pattern_count && p < 16u && matched; p++) {
            uint p_base = pattern_offset + p * 2u;
            uint p_uint0 = rule_data[p_base];
            uint p_uint1 = rule_data[p_base + 1u];

            ivec3 offset = decodeOffset(p_uint0);
            ivec3 check_pos = pos + offset;

            if (!isValidPos(check_pos)) {
                matched = false;
                break;
            }

            uint check_index = posToIndex(check_pos);
            Voxel neighbor = getPreviousVoxel(check_index);

            if (!matchesPattern(neighbor, p_uint0, p_uint1)) {
                matched = false;
            } else {
                matched_voxels[p] = neighbor;
            }
        }

        if (!matched) continue;

        // Check per-rule chance (0-100)
        if (chance < 100u && (rng.z % 100u) >= chance) continue;

        // Apply all result entries (4 uints each)
        for (uint r = 0u; r < result_count; r++) {
            uint r_base = result_offset + r * 4u;
            uint r_uint0 = rule_data[r_base];
            uint r_uint1 = rule_data[r_base + 1u];
            uint r_uint2 = rule_data[r_base + 2u];
            uint r_uint3 = rule_data[r_base + 3u];

            uint action = r_uint0 & 0xFFu;
            if (action == ACTION_KEEP) continue;

            ivec3 offset = decodeOffset(r_uint0);
            ivec3 write_pos = pos + offset;

            if (!isValidPos(write_pos)) continue;

            uint write_index = posToIndex(write_pos);
            Voxel expected = getPreviousVoxel(write_index);

            Voxel new_voxel;
            if (action == ACTION_SET_TYPE_AND_COLOR) {
                new_voxel = buildResultVoxel(r_uint1, r_uint2, r_uint3, write_pos);
            } else if (action == ACTION_COPY_FROM_PATTERN) {
                uint src_idx = (r_uint1 >> 16u) & 0xFFu;
                if (src_idx < 16u) {
                    new_voxel = matched_voxels[src_idx];
                } else {
                    continue;
                }
            } else if (action == ACTION_SET_AIR) {
                new_voxel = createAirVoxel();
            } else {
                continue;
            }

            // Write to BOTH ping-pong buffers to keep them in sync.
            // The edit pass uses setBothVoxelBuffers for the same reason —
            // without it, the "other" buffer has stale data from 2 frames ago
            // and CAS / reads on the next frame see the wrong state, causing flicker.
            setBothVoxelBuffers(write_index, new_voxel);
        }

        break; // First-match-wins: stop after first matching rule
    }
}
