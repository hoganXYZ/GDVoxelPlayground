
#ifndef VOXEL_WORLD_UPDATE_PASS_H
#define VOXEL_WORLD_UPDATE_PASS_H

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/rid.hpp>

#include "gdcs/include/gdcs.h"
#include "voxel_world/voxel_properties.h"

using namespace godot;

class VoxelWorldUpdatePass
{

  public:
    VoxelWorldUpdatePass(String shader_path, RenderingDevice *rd, VoxelWorldRIDs& voxel_world_rids, const Vector3i size);
    ~VoxelWorldUpdatePass() {};

    void update(float delta);

  private:
    ComputeShader *automata_cs_1 = nullptr;
    ComputeShader *automata_cs_2 = nullptr;
    ComputeShader *vine_growth_shader = nullptr;
    ComputeShader *cleanup_shader = nullptr;
    Vector3i _size;
};

#endif // VOXEL_WORLD_UPDATE_PASS_H
