#ifndef FLOW_FIELD_H
#define FLOW_FIELD_H

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include "gdcs/include/gdcs.h"
#include "voxel_world/voxel_properties.h"

using namespace godot;

class FlowField
{
public:
    FlowField() {};
    ~FlowField();

    void init(RenderingDevice *rd, VoxelWorldRIDs &voxel_world_rids, Vector3i world_size);
    void compute(const Vector3i &target);

    void debug_draw(int y_level);
    void debug_clear(int y_level);

    RID get_distance_buffer_rid() const { return _distance_buffer_rid; }

private:
    static constexpr int STEPS_PER_DISPATCH = 8;

    struct InitPushConstant
    {
        int target_x, target_y, target_z, pad;
    };

    struct StepPushConstant
    {
        uint32_t current_step;
        uint32_t steps_per_dispatch;
        uint32_t pad0, pad1;
    };

    struct DebugPushConstant
    {
        int y_level;
        uint32_t mode;         // 0 = draw, 1 = clear
        uint32_t max_distance;
        uint32_t pad;
    };

    ComputeShader *_init_shader = nullptr;
    ComputeShader *_step_shader = nullptr;
    ComputeShader *_debug_shader = nullptr;
    RenderingDevice *_rd = nullptr;

    RID _distance_buffer_rid;

    Vector3i _world_size;
    int _total_voxels = 0;
    int _num_dispatches = 0;
};

#endif // FLOW_FIELD_H
