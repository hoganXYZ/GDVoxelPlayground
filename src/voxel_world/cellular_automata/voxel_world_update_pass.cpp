

#include "voxel_world_update_pass.h"
#include <godot_cpp/core/print_string.hpp>

using namespace godot;

VoxelWorldUpdatePass::VoxelWorldUpdatePass(RenderingDevice *rd, VoxelWorldRIDs &voxel_world_rids, const Vector3i size)
    : _rd(rd), _rids(voxel_world_rids), _size(size)
{
    movement_shader = new ComputeShader("res://addons/voxel_playground/src/shaders/automata/movement.glsl", rd);
    voxel_world_rids.add_voxel_buffers(movement_shader);
    voxel_world_rids.add_ca_buffers(movement_shader);
    movement_shader->finish_create_uniforms();

    reaction_shader = new ComputeShader("res://addons/voxel_playground/src/shaders/automata/reaction.glsl", rd);
    voxel_world_rids.add_voxel_buffers(reaction_shader);
    voxel_world_rids.add_ca_buffers(reaction_shader);
    reaction_shader->finish_create_uniforms();

    cleanup_shader = new ComputeShader("res://addons/voxel_playground/src/shaders/automata/cleanup_pass.glsl", rd);
    voxel_world_rids.add_voxel_buffers(cleanup_shader);
    voxel_world_rids.add_ca_buffers(cleanup_shader);
    cleanup_shader->finish_create_uniforms();

    explosion_shader = new ComputeShader("res://addons/voxel_playground/src/shaders/automata/explosion_pass.glsl", rd);
    voxel_world_rids.add_voxel_buffers(explosion_shader);
    voxel_world_rids.add_ca_buffers(explosion_shader);
    explosion_shader->add_existing_buffer(voxel_world_rids.explosions, RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER, 15, 1);
    explosion_shader->finish_create_uniforms();
}

VoxelWorldUpdatePass::~VoxelWorldUpdatePass()
{
    delete movement_shader;
    delete reaction_shader;
    delete custom_shader;
    delete cleanup_shader;
    delete explosion_shader;
}

void VoxelWorldUpdatePass::set_custom_source(const String &source)
{
    if (source == _custom_source && (custom_shader != nullptr || source.is_empty()))
        return;
    _custom_source = source;
    delete custom_shader;
    custom_shader = nullptr;
    if (source.is_empty())
        return;

    // the virtual path anchors #include resolution next to the other automata shaders
    ComputeShader *shader = new ComputeShader(
        _rd, source, "res://addons/voxel_playground/src/shaders/automata/_generated_custom_pass.glsl");
    _rids.add_voxel_buffers(shader);
    _rids.add_ca_buffers(shader);
    shader->finish_create_uniforms();
    if (!shader->check_ready())
    {
        UtilityFunctions::printerr("VoxelWorldUpdatePass: custom pass failed to compile; disabling it");
        delete shader;
        return;
    }
    custom_shader = shader;
}

void VoxelWorldUpdatePass::run_movement()
{
    if (movement_shader == nullptr)
    {
        UtilityFunctions::printerr("VoxelWorldUpdatePass::run_movement() compute shader is null");
        return;
    }

    const Vector3 group_size = Vector3(8, 8, 8);
    const Vector3i group_count = Vector3i(std::ceil(_size.x / group_size.x), std::ceil(_size.y / group_size.y),
                                          std::ceil(_size.z / group_size.z));

    // two checkerboard sub-passes: face-adjacent cells never act concurrently
    struct PushConstants
    {
        uint32_t sub_pass;
        uint32_t pad0, pad1, pad2;
    } pc = {0u, 0u, 0u, 0u};

    movement_shader->set_push_constant(ComputeShader::struct_to_packed_byte_array(pc));
    movement_shader->compute(group_count, false);
    pc.sub_pass = 1u;
    movement_shader->set_push_constant(ComputeShader::struct_to_packed_byte_array(pc));
    movement_shader->compute(group_count, false);

    // Tier-4 custom kernels (runtime-compiled from element custom_glsl)
    if (custom_shader != nullptr)
        custom_shader->compute(group_count, false);
}

void VoxelWorldUpdatePass::run_reactions()
{
    if (reaction_shader == nullptr)
        return;
    const Vector3 group_size = Vector3(8, 8, 8);
    const Vector3i group_count = Vector3i(std::ceil(_size.x / group_size.x), std::ceil(_size.y / group_size.y),
                                          std::ceil(_size.z / group_size.z));
    reaction_shader->compute(group_count, false);
}

void VoxelWorldUpdatePass::run_explosions()
{
    if (explosion_shader == nullptr)
        return;
    const Vector3 group_size = Vector3(8, 8, 8);
    const Vector3i group_count = Vector3i(std::ceil(_size.x / group_size.x), std::ceil(_size.y / group_size.y),
                                          std::ceil(_size.z / group_size.z));
    explosion_shader->compute(group_count, false);
}

void VoxelWorldUpdatePass::run_cleanup()
{
    if (cleanup_shader == nullptr)
        return;

    const Vector3 thread_span = Vector3(2, 4, 2);
    const Vector3 group_size = Vector3(4, 2, 4);
    const Vector3 brick_span = thread_span * group_size;
    const Vector3i group_count = Vector3i(std::ceil(_size.x / brick_span.x), std::ceil(_size.y / brick_span.y),
                                          std::ceil(_size.z / brick_span.z));
    cleanup_shader->compute(group_count, false);
}
