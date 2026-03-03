

#include "voxel_edit_pass.h"
#include <godot_cpp/core/print_string.hpp>  // For print_line()

using namespace godot;


VoxelEditPass::VoxelEditPass(String shader_path, RenderingDevice * rd, VoxelWorldRIDs& voxel_world_rids, const Vector3i size) : _size(size){

    _edit_params = {
        Vector4(1, 1, 1, 1), // camera_origin
        Vector4(0, 0, -1, 0), // camera_direction
        Vector4(0, 0, 0, 1), // hit_position
        0.1f, // near
        100.0f, // range
        100.0f, // radius
        0 //value
    };

    ray_cast_shader = new ComputeShader("res://addons/voxel_playground/src/shaders/voxel_edit/raycast.glsl", rd);
    voxel_world_rids.add_voxel_buffers(ray_cast_shader);
    _edit_params_rid = ray_cast_shader->create_storage_buffer_uniform(_edit_params.to_packed_byte_array(), 0, 1);
    ray_cast_shader->finish_create_uniforms();

    edit_shader = new ComputeShader(shader_path, rd);
    voxel_world_rids.add_voxel_buffers(edit_shader);
    edit_shader->add_existing_buffer(_edit_params_rid, RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER, 0, 1);
    edit_shader->finish_create_uniforms();
}

void VoxelEditPass::edit_using_raycast(const Vector3 &camera_origin, const Vector3 &camera_direction, const float radius, const float range, const int value)
{
    if (ray_cast_shader == nullptr || !ray_cast_shader->check_ready() || edit_shader == nullptr || !edit_shader->check_ready()) 
    {
        UtilityFunctions::printerr("VoxelEditPass::update() edit shader is null or not ready");
        return;
    }

    _edit_params.camera_origin = Vector4(camera_origin.x, camera_origin.y, camera_origin.z, 1.0f);
    _edit_params.camera_direction = Vector4(camera_direction.x, camera_direction.y, camera_direction.z, 0.0f).normalized();
    _edit_params.hit_position = Vector4(0, 0, 0, -1);
    _edit_params.near = 0.1f;
    _edit_params.far = range;
    _edit_params.radius = radius;
    _edit_params.value = value;

    //raycast
    ray_cast_shader->update_storage_buffer_uniform(_edit_params_rid, _edit_params.to_packed_byte_array());
    ray_cast_shader->compute(Vector3i(1,1,1), false); 

    PackedByteArray arr =  ray_cast_shader->get_storage_buffer_uniform(_edit_params_rid);
    VoxelEditParams *params = reinterpret_cast<VoxelEditParams *>(arr.ptrw());
    // UtilityFunctions::print(params->hit_position);

    //edit at found position
    const Vector3 group_size = Vector3(8, 8, 8);
    const Vector3i group_count = Vector3i(std::ceil(2.0f * radius / group_size.x), std::ceil(2.0f * radius / group_size.y), std::ceil(2.0f * radius / group_size.z));
    edit_shader->compute(group_count, false);
}

void VoxelEditPass::edit_at(const Vector3 &position, const float radius, const int value)
{
}

Vector3 VoxelEditPass::raycast(const Vector3 &camera_origin, const Vector3 &camera_direction, const float range)
{
    if (ray_cast_shader == nullptr || !ray_cast_shader->check_ready())
    {
        return Vector3(-1, -1, -1);
    }

    _edit_params.camera_origin = Vector4(camera_origin.x, camera_origin.y, camera_origin.z, 1.0f);
    _edit_params.camera_direction = Vector4(camera_direction.x, camera_direction.y, camera_direction.z, 0.0f).normalized();
    _edit_params.hit_position = Vector4(0, 0, 0, -1);
    _edit_params.near = 0.1f;
    _edit_params.far = range;
    _edit_params.radius = 0;
    _edit_params.value = 0;

    ray_cast_shader->update_storage_buffer_uniform(_edit_params_rid, _edit_params.to_packed_byte_array());
    ray_cast_shader->compute(Vector3i(1, 1, 1), false);

    PackedByteArray arr = ray_cast_shader->get_storage_buffer_uniform(_edit_params_rid);
    VoxelEditParams *params = reinterpret_cast<VoxelEditParams *>(arr.ptrw());

    if (params->hit_position.w > 0)
    {
        return Vector3(params->hit_position.x, params->hit_position.y, params->hit_position.z);
    }
    return Vector3(-1, -1, -1);
}
