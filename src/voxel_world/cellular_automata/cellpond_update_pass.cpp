#include "cellpond_update_pass.h"
#include <godot_cpp/variant/utility_functions.hpp>
#include <cmath>

using namespace godot;

// Pre-allocate 64KB for rule buffer — enough for ~256 complex rules.
// This avoids needing to recreate/resize the GPU buffer at runtime.
static constexpr int RULE_BUFFER_CAPACITY = 65536;

CellPondUpdatePass::CellPondUpdatePass(RenderingDevice *rd, VoxelWorldRIDs &voxel_world_rids, const Vector3i size)
    : _rd(rd), _size(size)
{
    _cellpond_cs = new ComputeShader(
        "res://addons/voxel_playground/src/shaders/automata/cellpond_rules.glsl", rd);
    voxel_world_rids.add_voxel_buffers(_cellpond_cs);

    // Pre-allocate large rule buffer, zeroed out (rule_count=0 in header)
    PackedByteArray empty_rules;
    empty_rules.resize(RULE_BUFFER_CAPACITY);
    memset(empty_rules.ptrw(), 0, RULE_BUFFER_CAPACITY);
    _rule_buffer_rid = _cellpond_cs->create_storage_buffer_uniform(empty_rules, 0, 1);

    _cellpond_cs->finish_create_uniforms();
}

void CellPondUpdatePass::update(float delta)
{
    if (_cellpond_cs == nullptr)
    {
        UtilityFunctions::printerr("CellPondUpdatePass::update() compute shader is null");
        return;
    }

    const Vector3 group_size = Vector3(8, 8, 8);
    const Vector3i group_count = Vector3i(
        std::ceil(_size.x / group_size.x),
        std::ceil(_size.y / group_size.y),
        std::ceil(_size.z / group_size.z));
    _cellpond_cs->compute(group_count, false);
}

void CellPondUpdatePass::set_rules(const PackedByteArray &rule_buffer)
{
    if (_cellpond_cs == nullptr)
        return;

    if (rule_buffer.size() > RULE_BUFFER_CAPACITY)
    {
        UtilityFunctions::printerr("CellPondUpdatePass: rule buffer exceeds 64KB capacity!");
        return;
    }

    _cellpond_cs->update_storage_buffer_uniform(_rule_buffer_rid, rule_buffer);
}
