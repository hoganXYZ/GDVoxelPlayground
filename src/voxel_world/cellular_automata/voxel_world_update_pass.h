
#ifndef VOXEL_WORLD_UPDATE_PASS_H
#define VOXEL_WORLD_UPDATE_PASS_H

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/rid.hpp>

#include "gdcs/include/gdcs.h"
#include "voxel_world/voxel_properties.h"

using namespace godot;

// Dispatches the data-driven CA pipeline (see docs/runtime_ca_design.md):
//   run_movement():  generic movement pass (two checkerboard sub-passes) +
//                    custom kernels (vine growth)
//   run_cleanup():   erase dynamics from the read buffer, rebuild occupancy
//   run_reactions(): contact reactions, heat, life decay, phase changes
//                    (must run on its own buffer flip; the caller increments
//                    the frame counter between movement and reactions)
class VoxelWorldUpdatePass
{

  public:
    VoxelWorldUpdatePass(RenderingDevice *rd, VoxelWorldRIDs &voxel_world_rids, const Vector3i size);
    ~VoxelWorldUpdatePass();

    void run_movement();
    void run_reactions();
    void run_cleanup();

  private:
    ComputeShader *movement_shader = nullptr;
    ComputeShader *reaction_shader = nullptr;
    ComputeShader *vine_growth_shader = nullptr;
    ComputeShader *cleanup_shader = nullptr;
    Vector3i _size;
};

#endif // VOXEL_WORLD_UPDATE_PASS_H
