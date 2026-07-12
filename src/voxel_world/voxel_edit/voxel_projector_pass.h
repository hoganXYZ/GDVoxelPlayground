#ifndef VOXEL_PROJECTOR_PASS_H
#define VOXEL_PROJECTOR_PASS_H

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/projection.hpp>
#include <godot_cpp/variant/rid.hpp>

#include "gdcs/include/gdcs.h"
#include "voxel_world/voxel_properties.h"

using namespace godot;

// Stamps a 2D texture into the voxel world through a projector frustum:
// every texel above the alpha threshold traces a ray and converts the voxel
// it hits into the requested element, colored by the texel.
class VoxelProjectorPass
{
    struct ProjectorParams
    {
        float inv_view_projection[16];
        Vector4 origin;
        Vector4 right_extent;
        Vector4 up_extent;
        Vector4 direction;
        Vector4 tint;
        int32_t tex_width;
        int32_t tex_height;
        float alpha_threshold;
        float max_range;
        uint32_t value;
        uint32_t place_on_surface;
        uint32_t ray_mode; // 0 = perspective, 1 = parallel (ortho/oblique)
        uint32_t _pad0;

        PackedByteArray to_packed_byte_array()
        {
            PackedByteArray byte_array;
            byte_array.resize(sizeof(ProjectorParams));
            std::memcpy(byte_array.ptrw(), this, sizeof(ProjectorParams));
            return byte_array;
        }
    };

  public:
    VoxelProjectorPass(RenderingDevice *rd, VoxelWorldRIDs &voxel_world_rids);
    ~VoxelProjectorPass();

    void project(const RID &texture, const Vector2i &texture_size, const Projection &inv_view_projection,
                 const Vector3 &origin, const int value, const Color &tint, const float alpha_threshold,
                 const float max_range, const bool place_on_surface);

    // Parallel-ray variant (ortho/oblique cameras): ray origin = origin +
    // ndc.x * right_extent + ndc.y * up_extent, all rays share `direction`.
    void project_parallel(const RID &texture, const Vector2i &texture_size, const Vector3 &origin,
                          const Vector3 &right_extent, const Vector3 &up_extent, const Vector3 &direction,
                          const int value, const Color &tint, const float alpha_threshold, const float max_range,
                          const bool place_on_surface);

  private:
    void _dispatch(const RID &texture, const Vector2i &texture_size, const int value, const Color &tint,
                   const float alpha_threshold, const float max_range, const bool place_on_surface);

    ComputeShader *_shader = nullptr;
    RID _params_rid;
    RID _bound_texture;
    ProjectorParams _params;
};

#endif // VOXEL_PROJECTOR_PASS_H
