#include "flow_field.h"
#include <godot_cpp/variant/utility_functions.hpp>
#include <cmath>
#include <cstring>

using namespace godot;

FlowField::~FlowField()
{
    delete _init_shader;
    delete _step_shader;
    delete _debug_shader;
}

void FlowField::init(RenderingDevice *rd, VoxelWorldRIDs &voxel_world_rids, Vector3i world_size)
{
    _rd = rd;
    _world_size = world_size;
    _total_voxels = world_size.x * world_size.y * world_size.z;

    // Compute number of BFS dispatches needed to cover the entire grid.
    // Max Manhattan distance = (x-1) + (y-1) + (z-1). With STEPS_PER_DISPATCH steps
    // per dispatch, we need ceil(max_dist / steps) dispatches.
    int max_manhattan = (world_size.x - 1) + (world_size.y - 1) + (world_size.z - 1);
    _num_dispatches = (max_manhattan + STEPS_PER_DISPATCH - 1) / STEPS_PER_DISPATCH;

    // --- Init shader: clears distance buffer and seeds target cell ---
    _init_shader = new ComputeShader(
        "res://addons/voxel_playground/src/shaders/entity/flow_field_init.glsl", rd);
    voxel_world_rids.add_voxel_buffers(_init_shader);

    // Distance buffer: 1 uint32 per voxel cell (only low 16 bits used)
    PackedByteArray dist_data;
    dist_data.resize(_total_voxels * sizeof(uint32_t));
    memset(dist_data.ptrw(), 0xFF, dist_data.size()); // all 0xFFFFFFFF = unreachable
    _distance_buffer_rid = _init_shader->create_storage_buffer_uniform(dist_data, 0, 1);

    _init_shader->finish_create_uniforms();

    // --- Step shader: BFS wavefront expansion ---
    _step_shader = new ComputeShader(
        "res://addons/voxel_playground/src/shaders/entity/flow_field_step.glsl", rd);
    voxel_world_rids.add_voxel_buffers(_step_shader);

    // Bind the same distance buffer
    _step_shader->add_existing_buffer(
        _distance_buffer_rid, RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER, 0, 1);

    _step_shader->finish_create_uniforms();

    // --- Debug shader: Y-slice flow field visualization ---
    _debug_shader = new ComputeShader(
        "res://addons/voxel_playground/src/shaders/entity/flow_field_debug.glsl", rd);
    voxel_world_rids.add_voxel_buffers(_debug_shader);

    _debug_shader->add_existing_buffer(
        _distance_buffer_rid, RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER, 0, 1);

    _debug_shader->finish_create_uniforms();
}

void FlowField::compute(const Vector3i &target)
{
    if (_init_shader == nullptr || _step_shader == nullptr)
        return;

    if (target.x < 0 || target.x >= _world_size.x ||
        target.y < 0 || target.y >= _world_size.y ||
        target.z < 0 || target.z >= _world_size.z)
    {
        UtilityFunctions::printerr("FlowField: target out of bounds: ", target);
        return;
    }

    int group_count = std::max(1, (int)std::ceil((float)_total_voxels / 64.0f));

    // Step 1: Initialize - clear all distances to 0xFFFF and seed target with 0
    InitPushConstant init_pc = {};
    init_pc.target_x = target.x;
    init_pc.target_y = target.y;
    init_pc.target_z = target.z;
    init_pc.pad = 0;

    PackedByteArray init_pc_data;
    init_pc_data.resize(sizeof(InitPushConstant));
    memcpy(init_pc_data.ptrw(), &init_pc, sizeof(InitPushConstant));
    _init_shader->set_push_constant(init_pc_data);
    _init_shader->compute(Vector3i(group_count, 1, 1), false);

    // Step 2: Iterative BFS wavefront expansion.
    // No submit+sync needed — Godot inserts pipeline barriers between compute lists,
    // so each dispatch sees writes from the previous one. We run a fixed number of
    // dispatches to cover the maximum possible BFS distance.
    for (int i = 0; i < _num_dispatches; i++)
    {
        StepPushConstant step_pc = {};
        step_pc.current_step = static_cast<uint32_t>(i * STEPS_PER_DISPATCH);
        step_pc.steps_per_dispatch = static_cast<uint32_t>(STEPS_PER_DISPATCH);
        step_pc.pad0 = 0;
        step_pc.pad1 = 0;

        PackedByteArray step_pc_data;
        step_pc_data.resize(sizeof(StepPushConstant));
        memcpy(step_pc_data.ptrw(), &step_pc, sizeof(StepPushConstant));
        _step_shader->set_push_constant(step_pc_data);
        _step_shader->compute(Vector3i(group_count, 1, 1), false);
    }

    UtilityFunctions::print("FlowField: BFS dispatched ", _num_dispatches,
                            " iterations (", _num_dispatches * STEPS_PER_DISPATCH, " max steps) for target ", target);
}

void FlowField::debug_draw(int y_level)
{
    if (_debug_shader == nullptr)
        return;

    if (y_level < 0 || y_level >= _world_size.y)
        return;

    int slice_cells = _world_size.x * _world_size.z;
    int group_count = std::max(1, (int)std::ceil((float)slice_cells / 64.0f));

    DebugPushConstant pc = {};
    pc.y_level = y_level;
    pc.mode = 0; // draw
    pc.max_distance = static_cast<uint32_t>((_world_size.x - 1) + (_world_size.y - 1) + (_world_size.z - 1));
    pc.pad = 0;

    PackedByteArray pc_data;
    pc_data.resize(sizeof(DebugPushConstant));
    memcpy(pc_data.ptrw(), &pc, sizeof(DebugPushConstant));
    _debug_shader->set_push_constant(pc_data);
    _debug_shader->compute(Vector3i(group_count, 1, 1), false);
}

void FlowField::debug_clear(int y_level)
{
    if (_debug_shader == nullptr)
        return;

    if (y_level < 0 || y_level >= _world_size.y)
        return;

    int slice_cells = _world_size.x * _world_size.z;
    int group_count = std::max(1, (int)std::ceil((float)slice_cells / 64.0f));

    DebugPushConstant pc = {};
    pc.y_level = y_level;
    pc.mode = 1; // clear
    pc.max_distance = 0;
    pc.pad = 0;

    PackedByteArray pc_data;
    pc_data.resize(sizeof(DebugPushConstant));
    memcpy(pc_data.ptrw(), &pc, sizeof(DebugPushConstant));
    _debug_shader->set_push_constant(pc_data);
    _debug_shader->compute(Vector3i(group_count, 1, 1), false);
}
