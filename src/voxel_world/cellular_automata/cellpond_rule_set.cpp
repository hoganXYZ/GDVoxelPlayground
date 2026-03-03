#include "cellpond_rule_set.h"
#include <godot_cpp/variant/utility_functions.hpp>
#include <cstring>

using namespace godot;

void CellPondRuleSet::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("add_rule_from_arrays",
                                  "pattern_offsets", "pattern_types", "pattern_match_modes",
                                  "pattern_color_matches", "pattern_colors",
                                  "result_offsets", "result_actions", "result_types",
                                  "result_colors", "result_color_modes", "result_colors_max",
                                  "symmetry_mode", "weight", "chance"),
                         &CellPondRuleSet::add_rule_from_arrays);

    ClassDB::bind_method(D_METHOD("replace_rule",
                                  "index",
                                  "pattern_offsets", "pattern_types", "pattern_match_modes",
                                  "pattern_color_matches", "pattern_colors",
                                  "result_offsets", "result_actions", "result_types",
                                  "result_colors", "result_color_modes", "result_colors_max",
                                  "symmetry_mode", "weight", "chance"),
                         &CellPondRuleSet::replace_rule);

    ClassDB::bind_method(D_METHOD("remove_rule", "index"), &CellPondRuleSet::remove_rule);
    ClassDB::bind_method(D_METHOD("clear_rules"), &CellPondRuleSet::clear_rules);
    ClassDB::bind_method(D_METHOD("get_rule_count"), &CellPondRuleSet::get_rule_count);
    ClassDB::bind_method(D_METHOD("get_rule_data", "index"), &CellPondRuleSet::get_rule_data);

    ClassDB::bind_method(D_METHOD("set_activation_chance", "chance"), &CellPondRuleSet::set_activation_chance);
    ClassDB::bind_method(D_METHOD("get_activation_chance"), &CellPondRuleSet::get_activation_chance);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "activation_chance", PROPERTY_HINT_RANGE, "1,4,1"),
                 "set_activation_chance", "get_activation_chance");

    ClassDB::bind_method(D_METHOD("build_gpu_buffer"), &CellPondRuleSet::build_gpu_buffer);

    // Expose symmetry constants
    BIND_CONSTANT(CELLPOND_SYMMETRY_NONE);
    BIND_CONSTANT(CELLPOND_SYMMETRY_ROTATE_Y4);
    BIND_CONSTANT(CELLPOND_SYMMETRY_ROTATE_ALL24);
    BIND_CONSTANT(CELLPOND_SYMMETRY_FULL48);

    // Expose match mode constants
    BIND_CONSTANT(CELLPOND_MATCH_EXACT_TYPE);
    BIND_CONSTANT(CELLPOND_MATCH_ANY_SOLID);
    BIND_CONSTANT(CELLPOND_MATCH_ANY_LIQUID);
    BIND_CONSTANT(CELLPOND_MATCH_ANY_NON_AIR);
    BIND_CONSTANT(CELLPOND_MATCH_WILDCARD);
    BIND_CONSTANT(CELLPOND_MATCH_AIR_ONLY);

    // Expose action constants
    BIND_CONSTANT(CELLPOND_ACTION_SET_TYPE_AND_COLOR);
    BIND_CONSTANT(CELLPOND_ACTION_COPY_FROM_PATTERN);
    BIND_CONSTANT(CELLPOND_ACTION_SET_AIR);
    BIND_CONSTANT(CELLPOND_ACTION_KEEP);

    // Expose color mode constants
    BIND_CONSTANT(CELLPOND_COLOR_SOLID);
    BIND_CONSTANT(CELLPOND_COLOR_RANDOM_OKLAB);
}

CellPondRuleSet::Rule CellPondRuleSet::_build_rule_from_arrays(
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
    int chance) const
{
    Rule rule;
    rule.symmetry_mode = symmetry_mode;
    rule.weight = weight;
    rule.chance = CLAMP(chance, 0, 100);

    int pattern_count = pattern_offsets.size();
    for (int i = 0; i < pattern_count; i++)
    {
        Vector3i offset = pattern_offsets[i];
        CellPondPatternEntry entry;
        entry.dx = static_cast<int8_t>(CLAMP(offset.x, -7, 7));
        entry.dy = static_cast<int8_t>(CLAMP(offset.y, -7, 7));
        entry.dz = static_cast<int8_t>(CLAMP(offset.z, -7, 7));
        entry.match_mode = static_cast<uint8_t>(pattern_match_modes[i]);
        entry.match_type = static_cast<uint8_t>(pattern_types[i]);
        entry.color_match = (i < pattern_color_matches.size())
                                 ? static_cast<uint8_t>(pattern_color_matches[i])
                                 : 0;
        entry.match_color = (entry.color_match == 1 && i < pattern_colors.size())
                                ? static_cast<uint16_t>(Utils::compress_color16(pattern_colors[i]))
                                : 0;
        rule.pattern.push_back(entry);
    }

    int result_count = result_offsets.size();
    for (int i = 0; i < result_count; i++)
    {
        Vector3i offset = result_offsets[i];
        CellPondResultEntry entry;
        entry.dx = static_cast<int8_t>(CLAMP(offset.x, -7, 7));
        entry.dy = static_cast<int8_t>(CLAMP(offset.y, -7, 7));
        entry.dz = static_cast<int8_t>(CLAMP(offset.z, -7, 7));
        entry.action = static_cast<uint8_t>(result_actions[i]);
        entry.set_type = static_cast<uint8_t>(result_types[i]);
        entry.color_mode = static_cast<uint8_t>(result_color_modes[i]);
        entry.set_color = static_cast<uint16_t>(Utils::compress_color16(result_colors[i]));

        // OKLab range
        if (entry.color_mode == CELLPOND_COLOR_RANDOM_OKLAB)
        {
            Color c_min = result_colors[i];
            Color c_max = result_colors_max[i];
            Utils::rgb_to_oklab(c_min, entry.oklab_min[0], entry.oklab_min[1], entry.oklab_min[2]);
            Utils::rgb_to_oklab(c_max, entry.oklab_max[0], entry.oklab_max[1], entry.oklab_max[2]);
            // Ensure min <= max for each channel
            for (int c = 0; c < 3; c++)
            {
                if (entry.oklab_min[c] > entry.oklab_max[c])
                    std::swap(entry.oklab_min[c], entry.oklab_max[c]);
            }
        }
        else
        {
            memset(entry.oklab_min, 0, sizeof(entry.oklab_min));
            memset(entry.oklab_max, 0, sizeof(entry.oklab_max));
        }
        rule.result.push_back(entry);
    }

    return rule;
}

void CellPondRuleSet::add_rule_from_arrays(
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
    int chance)
{
    int pattern_count = pattern_offsets.size();
    int result_count = result_offsets.size();

    if (pattern_count != pattern_types.size() || pattern_count != pattern_match_modes.size() ||
        pattern_count != pattern_color_matches.size() || pattern_count != pattern_colors.size())
    {
        UtilityFunctions::printerr("CellPondRuleSet: Pattern array sizes don't match");
        return;
    }
    if (result_count != result_actions.size() || result_count != result_types.size() ||
        result_count != result_colors.size() || result_count != result_color_modes.size() ||
        result_count != result_colors_max.size())
    {
        UtilityFunctions::printerr("CellPondRuleSet: Result array sizes don't match");
        return;
    }

    _rules.push_back(_build_rule_from_arrays(
        pattern_offsets, pattern_types, pattern_match_modes,
        pattern_color_matches, pattern_colors,
        result_offsets, result_actions, result_types,
        result_colors, result_color_modes, result_colors_max,
        symmetry_mode, weight, chance));
}

void CellPondRuleSet::replace_rule(
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
    int chance)
{
    if (index < 0 || index >= static_cast<int>(_rules.size()))
    {
        UtilityFunctions::printerr("CellPondRuleSet: replace_rule index out of range");
        return;
    }

    int pattern_count = pattern_offsets.size();
    int result_count = result_offsets.size();

    if (pattern_count != pattern_types.size() || pattern_count != pattern_match_modes.size() ||
        pattern_count != pattern_color_matches.size() || pattern_count != pattern_colors.size())
    {
        UtilityFunctions::printerr("CellPondRuleSet: Pattern array sizes don't match");
        return;
    }
    if (result_count != result_actions.size() || result_count != result_types.size() ||
        result_count != result_colors.size() || result_count != result_color_modes.size() ||
        result_count != result_colors_max.size())
    {
        UtilityFunctions::printerr("CellPondRuleSet: Result array sizes don't match");
        return;
    }

    _rules[index] = _build_rule_from_arrays(
        pattern_offsets, pattern_types, pattern_match_modes,
        pattern_color_matches, pattern_colors,
        result_offsets, result_actions, result_types,
        result_colors, result_color_modes, result_colors_max,
        symmetry_mode, weight, chance);
}

Dictionary CellPondRuleSet::get_rule_data(int index) const
{
    Dictionary d;
    if (index < 0 || index >= static_cast<int>(_rules.size()))
        return d;

    const Rule &rule = _rules[index];

    TypedArray<Vector3i> pattern_offsets;
    PackedInt32Array pattern_types;
    PackedInt32Array pattern_match_modes;
    PackedInt32Array pattern_color_matches;
    PackedColorArray pattern_colors;

    for (const auto &p : rule.pattern)
    {
        pattern_offsets.append(Vector3i(p.dx, p.dy, p.dz));
        pattern_types.append(static_cast<int>(p.match_type));
        pattern_match_modes.append(static_cast<int>(p.match_mode));
        pattern_color_matches.append(static_cast<int>(p.color_match));
        pattern_colors.append(Utils::decompress_color16(p.match_color));
    }

    TypedArray<Vector3i> result_offsets;
    PackedInt32Array result_actions;
    PackedInt32Array result_types;
    PackedColorArray result_colors;
    PackedInt32Array result_color_modes;
    PackedColorArray result_colors_max;

    for (const auto &r : rule.result)
    {
        result_offsets.append(Vector3i(r.dx, r.dy, r.dz));
        result_actions.append(static_cast<int>(r.action));
        result_types.append(static_cast<int>(r.set_type));
        result_colors.append(Utils::decompress_color16(r.set_color));
        result_color_modes.append(static_cast<int>(r.color_mode));
        // Convert stored OKLab ranges back to sRGB for GDScript
        if (r.color_mode == CELLPOND_COLOR_RANDOM_OKLAB)
        {
            result_colors_max.append(
                Utils::oklab_to_rgb(r.oklab_max[0], r.oklab_max[1], r.oklab_max[2]));
        }
        else
        {
            result_colors_max.append(Utils::decompress_color16(r.set_color));
        }
    }

    d["pattern_offsets"] = pattern_offsets;
    d["pattern_types"] = pattern_types;
    d["pattern_match_modes"] = pattern_match_modes;
    d["pattern_color_matches"] = pattern_color_matches;
    d["pattern_colors"] = pattern_colors;
    d["result_offsets"] = result_offsets;
    d["result_actions"] = result_actions;
    d["result_types"] = result_types;
    d["result_colors"] = result_colors;
    d["result_color_modes"] = result_color_modes;
    d["result_colors_max"] = result_colors_max;
    d["symmetry_mode"] = rule.symmetry_mode;
    d["weight"] = rule.weight;
    d["chance"] = rule.chance;

    return d;
}

void CellPondRuleSet::remove_rule(int index)
{
    if (index >= 0 && index < static_cast<int>(_rules.size()))
    {
        _rules.erase(_rules.begin() + index);
    }
}

void CellPondRuleSet::clear_rules()
{
    _rules.clear();
}

int CellPondRuleSet::get_rule_count() const
{
    return static_cast<int>(_rules.size());
}

void CellPondRuleSet::set_activation_chance(int chance)
{
    _activation_chance = static_cast<uint32_t>(CLAMP(chance, 1, 4));
}

int CellPondRuleSet::get_activation_chance() const
{
    return static_cast<int>(_activation_chance);
}

PackedByteArray CellPondRuleSet::build_gpu_buffer() const
{
    // Step 1: Expand all rules with symmetry
    struct ExpandedRule
    {
        std::vector<CellPondPatternEntry> pattern;
        std::vector<CellPondResultEntry> result;
        int chance;
    };

    std::vector<ExpandedRule> expanded_rules;

    for (const auto &rule : _rules)
    {
        auto rotations = get_symmetry_rotations(rule.symmetry_mode);
        bool include_reflections = (rule.symmetry_mode == CELLPOND_SYMMETRY_FULL48);

        for (const auto &rot : rotations)
        {
            ExpandedRule expanded;
            expanded.chance = rule.chance;
            for (const auto &p : rule.pattern)
                expanded.pattern.push_back(transform_pattern_entry(p, rot));
            for (const auto &r : rule.result)
                expanded.result.push_back(transform_result_entry(r, rot));
            expanded_rules.push_back(expanded);

            if (include_reflections)
            {
                ExpandedRule reflected;
                reflected.chance = rule.chance;
                for (const auto &p : expanded.pattern)
                {
                    CellPondPatternEntry rp = p;
                    rp.dx = -rp.dx;
                    rp.dy = -rp.dy;
                    rp.dz = -rp.dz;
                    reflected.pattern.push_back(rp);
                }
                for (const auto &r : expanded.result)
                {
                    CellPondResultEntry rr = r;
                    rr.dx = -rr.dx;
                    rr.dy = -rr.dy;
                    rr.dz = -rr.dz;
                    reflected.result.push_back(rr);
                }
                expanded_rules.push_back(reflected);
            }
        }
    }

    if (expanded_rules.size() > 256)
    {
        UtilityFunctions::print_rich("[color=yellow]CellPond: Capping expanded rules at 256 (had ",
                                      (int)expanded_rules.size(), ")[/color]");
        expanded_rules.resize(256);
    }

    // Step 2: Calculate buffer layout
    // Rule headers are now 4 uints each (was 3), result entries are 4 uints each (was 2)
    uint32_t rule_count = static_cast<uint32_t>(expanded_rules.size());
    uint32_t header_uints = 4;                    // CellPondBufferHeader
    uint32_t rule_headers_uints = rule_count * 4; // 4 uints per rule header (was 3)
    uint32_t data_start = header_uints + rule_headers_uints;

    uint32_t total_pattern_uints = 0;
    uint32_t total_result_uints = 0;
    for (const auto &rule : expanded_rules)
    {
        total_pattern_uints += static_cast<uint32_t>(rule.pattern.size()) * 2; // 2 uints each
        total_result_uints += static_cast<uint32_t>(rule.result.size()) * 4;   // 4 uints each (was 2)
    }

    uint32_t total_uints = data_start + total_pattern_uints + total_result_uints;

    // Step 3: Pack the buffer
    std::vector<uint32_t> buffer(total_uints, 0);

    buffer[0] = rule_count;
    buffer[1] = total_uints;
    buffer[2] = _activation_chance;
    buffer[3] = 0; // pad

    uint32_t current_data_offset = data_start;

    for (uint32_t i = 0; i < rule_count; i++)
    {
        const auto &rule = expanded_rules[i];
        uint32_t pattern_count = static_cast<uint32_t>(rule.pattern.size());
        uint32_t result_count = static_cast<uint32_t>(rule.result.size());

        uint32_t header_idx = header_uints + i * 4; // 4 uints per header (was 3)
        buffer[header_idx + 0] = (result_count << 16) | (pattern_count & 0xFFFF);
        buffer[header_idx + 1] = current_data_offset; // pattern offset

        // Write pattern entries (2 uints each)
        for (uint32_t p = 0; p < pattern_count; p++)
        {
            buffer[current_data_offset++] = rule.pattern[p].pack_uint0();
            buffer[current_data_offset++] = rule.pattern[p].pack_uint1();
        }

        buffer[header_idx + 2] = current_data_offset; // result offset

        // Write result entries (4 uints each)
        for (uint32_t r = 0; r < result_count; r++)
        {
            buffer[current_data_offset++] = rule.result[r].pack_uint0();
            buffer[current_data_offset++] = rule.result[r].pack_uint1();
            buffer[current_data_offset++] = rule.result[r].pack_uint2();
            buffer[current_data_offset++] = rule.result[r].pack_uint3();
        }

        buffer[header_idx + 3] = static_cast<uint32_t>(CLAMP(rule.chance, 0, 100)); // chance
    }

    PackedByteArray byte_array;
    byte_array.resize(total_uints * sizeof(uint32_t));
    std::memcpy(byte_array.ptrw(), buffer.data(), byte_array.size());

    return byte_array;
}
