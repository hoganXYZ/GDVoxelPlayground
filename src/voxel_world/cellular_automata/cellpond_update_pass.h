#ifndef CELLPOND_UPDATE_PASS_H
#define CELLPOND_UPDATE_PASS_H

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/variant/rid.hpp>

#include "gdcs/include/gdcs.h"
#include "voxel_world/voxel_properties.h"

using namespace godot;

class CellPondUpdatePass
{
public:
    CellPondUpdatePass(RenderingDevice *rd, VoxelWorldRIDs &voxel_world_rids, const Vector3i size);
    ~CellPondUpdatePass() {};

    void update(float delta);
    void set_rules(const PackedByteArray &rule_buffer);

private:
    ComputeShader *_cellpond_cs = nullptr;
    RenderingDevice *_rd = nullptr;
    RID _rule_buffer_rid;
    Vector3i _size;
};

#endif // CELLPOND_UPDATE_PASS_H
