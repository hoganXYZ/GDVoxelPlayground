#ifndef CELLPOND_RULE_SET_H
#define CELLPOND_RULE_SET_H

#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include "cellpond_rule.h"
#include "cellpond_symmetry.h"
#include "utils.h"

#include <vector>

using namespace godot;

class CellPondRuleSet : public Resource
{
    GDCLASS(CellPondRuleSet, Resource);

public:
    struct Rule
    {
        std::vector<CellPondPatternEntry> pattern;
        std::vector<CellPondResultEntry> result;
        int symmetry_mode;
        int weight;
        int chance; // 0-100 percentage
    };

protected:
    static void _bind_methods();

private:
    std::vector<Rule> _rules;
    uint32_t _activation_chance = 1; // 1 out of 4 voxels activate per frame

    // Helper to build a Rule from arrays (shared by add/replace)
    Rule _build_rule_from_arrays(
        const TypedArray<Vector3i> &pattern_offsets,
        const PackedInt32Array &pattern_types,
        const PackedInt32Array &pattern_match_modes,
        const PackedInt32Array &pattern_color_matches,
        const PackedColorArray &pattern_colors,
        const TypedArray<Vector3i> &result_offsets,
        const PackedInt32Array &result_actions,
        const PackedInt32Array &result_types,
        const PackedColorArray &result_colors,
        const PackedInt32Array &result_color_modes,
        const PackedColorArray &result_colors_max,
        int symmetry_mode,
        int weight,
        int chance) const;

public:
    CellPondRuleSet() = default;
    ~CellPondRuleSet() = default;

    void add_rule_from_arrays(
        const TypedArray<Vector3i> &pattern_offsets,
        const PackedInt32Array &pattern_types,
        const PackedInt32Array &pattern_match_modes,
        const PackedInt32Array &pattern_color_matches,
        const PackedColorArray &pattern_colors,
        const TypedArray<Vector3i> &result_offsets,
        const PackedInt32Array &result_actions,
        const PackedInt32Array &result_types,
        const PackedColorArray &result_colors,
        const PackedInt32Array &result_color_modes,
        const PackedColorArray &result_colors_max,
        int symmetry_mode,
        int weight,
        int chance);

    void replace_rule(
        int index,
        const TypedArray<Vector3i> &pattern_offsets,
        const PackedInt32Array &pattern_types,
        const PackedInt32Array &pattern_match_modes,
        const PackedInt32Array &pattern_color_matches,
        const PackedColorArray &pattern_colors,
        const TypedArray<Vector3i> &result_offsets,
        const PackedInt32Array &result_actions,
        const PackedInt32Array &result_types,
        const PackedColorArray &result_colors,
        const PackedInt32Array &result_color_modes,
        const PackedColorArray &result_colors_max,
        int symmetry_mode,
        int weight,
        int chance);

    void remove_rule(int index);
    void clear_rules();
    int get_rule_count() const;
    Dictionary get_rule_data(int index) const;

    void set_activation_chance(int chance);
    int get_activation_chance() const;

    PackedByteArray build_gpu_buffer() const;
};

#endif // CELLPOND_RULE_SET_H
