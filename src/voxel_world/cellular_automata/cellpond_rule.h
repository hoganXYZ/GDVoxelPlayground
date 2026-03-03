#ifndef CELLPOND_RULE_H
#define CELLPOND_RULE_H

#include <algorithm>
#include <cstdint>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace godot
{

// Match modes for pattern entries
enum CellPondMatchMode : uint8_t
{
    CELLPOND_MATCH_EXACT_TYPE = 0,
    CELLPOND_MATCH_ANY_SOLID = 1,
    CELLPOND_MATCH_ANY_LIQUID = 2,
    CELLPOND_MATCH_ANY_NON_AIR = 3,
    CELLPOND_MATCH_WILDCARD = 4,
    CELLPOND_MATCH_AIR_ONLY = 5,
};

// Actions for result entries
enum CellPondAction : uint8_t
{
    CELLPOND_ACTION_SET_TYPE_AND_COLOR = 0,
    CELLPOND_ACTION_COPY_FROM_PATTERN = 1,
    CELLPOND_ACTION_SET_AIR = 2,
    CELLPOND_ACTION_KEEP = 3,
};

// Symmetry modes
enum CellPondSymmetry : int
{
    CELLPOND_SYMMETRY_NONE = 0,
    CELLPOND_SYMMETRY_ROTATE_Y4 = 1,
    CELLPOND_SYMMETRY_ROTATE_ALL24 = 2,
    CELLPOND_SYMMETRY_FULL48 = 3,
};

// A single pattern entry: what to match at a given offset
// Packed into 2 uints for GPU:
//   uint0: (dx+128)<<24 | (dy+128)<<16 | (dz+128)<<8 | match_mode
//   uint1: match_type<<24 | color_match<<16 | match_color(16 bits)
struct CellPondPatternEntry
{
    int8_t dx, dy, dz;
    uint8_t match_mode;
    uint8_t match_type;
    uint8_t color_match; // 0=don't care, 1=exact, 2=same-as-entry-N
    uint16_t match_color; // 16-bit compressed HSV

    uint32_t pack_uint0() const
    {
        return (uint32_t(uint8_t(dx + 128)) << 24) |
               (uint32_t(uint8_t(dy + 128)) << 16) |
               (uint32_t(uint8_t(dz + 128)) << 8) |
               uint32_t(match_mode);
    }

    uint32_t pack_uint1() const
    {
        return (uint32_t(match_type) << 24) |
               (uint32_t(color_match) << 16) |
               uint32_t(match_color);
    }
};

// Color modes for result entries
enum CellPondColorMode : uint8_t
{
    CELLPOND_COLOR_SOLID = 0,
    CELLPOND_COLOR_RANDOM_OKLAB = 1,
};

// A single result entry: what to write at a given offset
// Packed into 4 uints for GPU:
//   uint0: (dx+128)<<24 | (dy+128)<<16 | (dz+128)<<8 | action
//   uint1: set_type<<24 | color_mode<<16 | set_color(16 bits)
//   uint2: minL(8) | mina(8) | minb(8) | maxL(8)   (OKLab range, quantized)
//   uint3: maxa(8) | maxb(8) | padding(16)
struct CellPondResultEntry
{
    int8_t dx, dy, dz;
    uint8_t action;
    uint8_t set_type;
    uint8_t color_mode;   // 0=solid, 1=random_oklab
    uint16_t set_color;   // 16-bit compressed HSV for solid mode

    // OKLab range for random mode
    float oklab_min[3]; // L, a, b minimums
    float oklab_max[3]; // L, a, b maximums

    uint32_t pack_uint0() const
    {
        return (uint32_t(uint8_t(dx + 128)) << 24) |
               (uint32_t(uint8_t(dy + 128)) << 16) |
               (uint32_t(uint8_t(dz + 128)) << 8) |
               uint32_t(action);
    }

    uint32_t pack_uint1() const
    {
        return (uint32_t(set_type) << 24) |
               (uint32_t(color_mode) << 16) |
               uint32_t(set_color);
    }

    // Quantize OKLab float to 8-bit: L [0,1]→[0,255], a/b [-0.5,0.5]→[0,255]
    static uint8_t quantize_L(float v) { return static_cast<uint8_t>(std::clamp(v, 0.0f, 1.0f) * 255.0f); }
    static uint8_t quantize_ab(float v) { return static_cast<uint8_t>(std::clamp(v + 0.5f, 0.0f, 1.0f) * 255.0f); }

    uint32_t pack_uint2() const
    {
        return (uint32_t(quantize_L(oklab_min[0])) << 24) |
               (uint32_t(quantize_ab(oklab_min[1])) << 16) |
               (uint32_t(quantize_ab(oklab_min[2])) << 8) |
               uint32_t(quantize_L(oklab_max[0]));
    }

    uint32_t pack_uint3() const
    {
        return (uint32_t(quantize_ab(oklab_max[1])) << 24) |
               (uint32_t(quantize_ab(oklab_max[2])) << 16);
    }
};

// GPU buffer header (4 uints)
struct CellPondBufferHeader
{
    uint32_t rule_count;
    uint32_t total_data_uints;
    uint32_t activation_chance; // how many out of 4 voxels activate (1-4)
    uint32_t _pad;
};

// Per-rule header in GPU buffer (4 uints)
struct CellPondRuleGPUHeader
{
    uint32_t counts;         // pattern_count in low 16, result_count in high 16
    uint32_t pattern_offset; // uint offset into rule_data for first pattern entry
    uint32_t result_offset;  // uint offset into rule_data for first result entry
    uint32_t chance;         // 0-100: percentage chance this rule fires when matched
};

} // namespace godot

#endif // CELLPOND_RULE_H
