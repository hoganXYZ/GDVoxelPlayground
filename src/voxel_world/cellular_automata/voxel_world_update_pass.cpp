

#include "voxel_world_update_pass.h"
#include <godot_cpp/core/print_string.hpp>

using namespace godot;

VoxelWorldUpdatePass::VoxelWorldUpdatePass(RenderingDevice *rd, VoxelWorldRIDs &voxel_world_rids, const Vector3i size)
    : _size(size)
{
    movement_shader = new ComputeShader("res://addons/voxel_playground/src/shaders/automata/movement.glsl", rd);
    voxel_world_rids.add_voxel_buffers(movement_shader);
    voxel_world_rids.add_ca_buffers(movement_shader);
    movement_shader->finish_create_uniforms();

    reaction_shader = new ComputeShader("res://addons/voxel_playground/src/shaders/automata/reaction.glsl", rd);
    voxel_world_rids.add_voxel_buffers(reaction_shader);
    voxel_world_rids.add_ca_buffers(reaction_shader);
    reaction_shader->finish_create_uniforms();

    vine_growth_shader = new ComputeShader("res://addons/voxel_playground/src/shaders/automata/vine_growth.glsl", rd);
    voxel_world_rids.add_voxel_buffers(vine_growth_shader);
    vine_growth_shader->finish_create_uniforms();

    cleanup_shader = new ComputeShader("res://addons/voxel_playground/src/shaders/automata/cleanup_pass.glsl", rd);
    voxel_world_rids.add_voxel_buffers(cleanup_shader);
    voxel_world_rids.add_ca_buffers(cleanup_shader);
    cleanup_shader->finish_create_uniforms();
}

VoxelWorldUpdatePass::~VoxelWorldUpdatePass()
{
    delete movement_shader;
    delete reaction_shader;
    delete vine_growth_shader;
    delete cleanup_shader;
}

void VoxelWorldUpdatePass::run_movement()
{
    if (movement_shader == nullptr || vine_growth_shader == nullptr)
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

    // custom kernels for MOVEMENT_CUSTOM elements
    vine_growth_shader->compute(group_count, false);
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
