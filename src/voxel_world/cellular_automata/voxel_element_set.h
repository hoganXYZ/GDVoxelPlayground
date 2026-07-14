#ifndef VOXEL_ELEMENT_SET_H
#define VOXEL_ELEMENT_SET_H

#include "voxel_element.h"
#include <cstdint>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

namespace godot
{

// GPU-side mirrors — must match the structs in voxel_elements.glsl.inc.

struct GpuElementDef
{
    uint32_t movement_class = 0;
    float density = 0.0f;
    float flow = 0.0f;
    uint32_t flags = 0;
    uint32_t temp_high_q = 0xFFFFFFFFu; // disabled
    uint32_t state_high = 0;
    uint32_t temp_low_q = 0; // disabled
    uint32_t state_low = 0;
    uint32_t life_init = 0;
    uint32_t life_into = 0;
    uint32_t initial_temp_q = 0;
    float heat_conduct = 0.0f;
    uint32_t reaction_offset = 0;
    uint32_t reaction_count = 0;
    float emission = 0.0f;
    uint32_t base_color16 = 0;
    uint32_t behavior_offset = 0;
    uint32_t behavior_count = 0;
    float inertial_resistance = 0.1f;  // 0-1 chance a passing mover fails to wake this powder; >=1 never wakes
    float friction_factor = 0.9f;      // 0-1 lateral velocity kept on ground contact
    uint32_t dispersion_rate = 4;      // liquids/gases: lateral cells searched per tick
    float explosion_resistance = 1.0f; // rays with strength below this are stopped/resisted
    uint32_t _pad0 = 0;
    uint32_t _pad1 = 0;
};
static_assert(sizeof(GpuElementDef) == 96, "GpuElementDef must match the GLSL struct layout");

struct GpuReactionRule
{
    uint32_t partner = 0;
    uint32_t self_becomes = 0xFFFFu; // ELEM_KEEP
    uint32_t chance = 0;             // 0-10000
    uint32_t temp_min_q = 0;         // disabled
    uint32_t temp_max_q = 0xFFFFFFFFu;
    int32_t temp_delta_q = 0;
    uint32_t flags = 0;
    uint32_t _pad = 0;
};
static_assert(sizeof(GpuReactionRule) == 32, "GpuReactionRule must match the GLSL struct layout");

struct GpuBehaviorOp
{
    uint32_t packed_offset = 0;
    uint32_t opcode = 0;
    uint32_t arg = 0;
    uint32_t chance = 0;
};
static_assert(sizeof(GpuBehaviorOp) == 16, "GpuBehaviorOp must match the GLSL struct layout");

// The element dictionary: index in the array = element id stored in the voxel
// type byte. Ids 0-7 are reserved for the builtins (air, solid, water, lava,
// sand, vine, entity, debug) so existing content keeps meaning the same thing;
// create_default() provides them plus a small demo chemistry.
class VoxelElementSet : public Resource
{
    GDCLASS(VoxelElementSet, Resource);

protected:
    static void _bind_methods();

private:
    Array elements; // VoxelElement resources

public:
    static const int MAX_ELEMENTS = 256;
    static const int MAX_REACTION_RULES = 4096;
    static const int MAX_BEHAVIOR_OPS = 4096;

    static const uint32_t ELEM_KEEP = 0xFFFFu;
    static const uint32_t ELEM_ANY = 0xFFFFu;
    static const uint32_t FLAG_DYNAMIC = 1u;
    static const uint32_t REACTION_GATE_ON_PARTNER = 1u;

    static uint32_t quantize_temp(float kelvin)
    {
        return (uint32_t)CLAMP(kelvin * 16.0f, 0.0f, 65535.0f);
    }

    void set_elements(const Array &v);
    Array get_elements() const { return elements; }

    int add_element(const Ref<VoxelElement> &element);
    int find_element_id(const String &name) const;
    Ref<VoxelElement> get_element(int id) const;
    Ref<VoxelElement> get_element_by_name(const String &name) const;
    int get_element_count() const { return elements.size(); }

    // Flattens the set into the three GPU tables. Returns false on error.
    bool build_tables(PackedByteArray &r_element_table, PackedByteArray &r_reaction_table,
                      PackedByteArray &r_behavior_table) const;

    // Tier 4: composes every element's custom_glsl into one compute shader
    // (compiled at runtime by the update pass). Empty string = no custom pass.
    String build_custom_source() const;

    static Ref<VoxelElementSet> create_default();
};

} // namespace godot

#endif // VOXEL_ELEMENT_SET_H
