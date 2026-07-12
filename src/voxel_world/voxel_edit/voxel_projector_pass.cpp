#include "voxel_projector_pass.h"
#include "utility/utils.h"
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

VoxelProjectorPass::VoxelProjectorPass(RenderingDevice *rd, VoxelWorldRIDs &voxel_world_rids)
{
    _params = {};
    _params.tint = Vector4(1, 1, 1, 1);
    _params.alpha_threshold = 0.5f;
    _params.max_range = 1000.0f;

    _shader = new ComputeShader("res://addons/voxel_playground/src/shaders/voxel_edit/texture_projector.glsl", rd);
    voxel_world_rids.add_voxel_buffers(_shader);
    voxel_world_rids.add_ca_buffers(_shader); // edits initialize the aux channel
    _params_rid = _shader->create_storage_buffer_uniform(_params.to_packed_byte_array(), 0, 1);
    // The projected texture is bound lazily on the first project() call; the
    // uniform set is finalized there.
}

VoxelProjectorPass::~VoxelProjectorPass()
{
    delete _shader;
    _shader = nullptr;
}

void VoxelProjectorPass::project(const RID &texture, const Vector2i &texture_size,
                                 const Projection &inv_view_projection, const Vector3 &origin, const int value,
                                 const Color &tint, const float alpha_threshold, const float max_range,
                                 const bool place_on_surface)
{
    Utils::projection_to_float(_params.inv_view_projection, inv_view_projection);
    _params.origin = Vector4(origin.x, origin.y, origin.z, 1.0f);
    _params.ray_mode = 0u;
    _dispatch(texture, texture_size, value, tint, alpha_threshold, max_range, place_on_surface);
}

void VoxelProjectorPass::project_parallel(const RID &texture, const Vector2i &texture_size, const Vector3 &origin,
                                          const Vector3 &right_extent, const Vector3 &up_extent,
                                          const Vector3 &direction, const int value, const Color &tint,
                                          const float alpha_threshold, const float max_range,
                                          const bool place_on_surface)
{
    _params.origin = Vector4(origin.x, origin.y, origin.z, 1.0f);
    _params.right_extent = Vector4(right_extent.x, right_extent.y, right_extent.z, 0.0f);
    _params.up_extent = Vector4(up_extent.x, up_extent.y, up_extent.z, 0.0f);
    _params.direction = Vector4(direction.x, direction.y, direction.z, 0.0f);
    _params.ray_mode = 1u;
    _dispatch(texture, texture_size, value, tint, alpha_threshold, max_range, place_on_surface);
}

void VoxelProjectorPass::_dispatch(const RID &texture, const Vector2i &texture_size, const int value,
                                   const Color &tint, const float alpha_threshold, const float max_range,
                                   const bool place_on_surface)
{
    if (_shader == nullptr || !texture.is_valid() || texture_size.x <= 0 || texture_size.y <= 0)
        return;

    // (Re)bind the texture if it changed — viewport texture RIDs change on resize.
    if (texture != _bound_texture)
    {
        if (_bound_texture.is_valid())
            _shader->replace_sampler_texture(texture, 1, 1);
        else
            _shader->add_sampler_with_texture(texture, 1, 1);
        _bound_texture = texture;
        _shader->finish_create_uniforms();
    }

    if (!_shader->check_ready())
    {
        UtilityFunctions::printerr("VoxelProjectorPass: shader not ready");
        return;
    }

    _params.tint = Vector4(tint.r, tint.g, tint.b, 1.0f);
    _params.tex_width = texture_size.x;
    _params.tex_height = texture_size.y;
    _params.alpha_threshold = alpha_threshold;
    _params.max_range = max_range;
    _params.value = static_cast<uint32_t>(value);
    _params.place_on_surface = place_on_surface ? 1u : 0u;

    _shader->update_storage_buffer_uniform(_params_rid, _params.to_packed_byte_array());

    const Vector3i group_count = Vector3i((texture_size.x + 15) / 16, (texture_size.y + 15) / 16, 1);
    _shader->compute(group_count, false);
}
