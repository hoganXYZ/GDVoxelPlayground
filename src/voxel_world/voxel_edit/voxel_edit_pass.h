
#ifndef VOXEL_WORLD_EDIT_PASS_H
#define VOXEL_WORLD_EDIT_PASS_H

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/rid.hpp>

#include "gdcs/include/gdcs.h"
#include "voxel_world/voxel_properties.h"

using namespace godot;

class VoxelEditPass
{
    struct VoxelEditParams
    {
        Vector4 camera_origin;
        Vector4 camera_direction;
        Vector4 hit_position;
        float near;
        float far;
        float radius;
        unsigned int value;

        PackedByteArray to_packed_byte_array()
        {
            PackedByteArray byte_array;
            byte_array.resize(sizeof(VoxelEditParams));
            std::memcpy(byte_array.ptrw(), this, sizeof(VoxelEditParams));
            return byte_array;
        }
    };

  public:
    VoxelEditPass(String edit_shader_path, RenderingDevice *rd, VoxelWorldRIDs &voxel_world_rids, const Vector3i size);
    ~VoxelEditPass() {};

    void edit_using_raycast(const Vector3 &camera_origin, const Vector3 &camera_direction, const float radius,
                            const float range, const int value);
    void edit_at(const Vector3 &position, const float radius, const int value);
    Vector3 raycast(const Vector3 &camera_origin, const Vector3 &camera_direction, const float range);

  private:
    ComputeShader *ray_cast_shader = nullptr;
    ComputeShader *edit_shader = nullptr;
    Vector3i _size;

    VoxelEditParams _edit_params;
    RID _edit_params_rid;
};

#endif // VOXEL_WORLD_EDIT_PASS_H
