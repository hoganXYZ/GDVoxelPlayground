#ifndef ENTITY_MANAGER_H
#define ENTITY_MANAGER_H

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/rid.hpp>

#include "gdcs/include/gdcs.h"
#include "voxel_world/voxel_properties.h"
#include "voxel_world/entity/flow_field.h"

using namespace godot;

class EntityManager : public Node3D
{
    GDCLASS(EntityManager, Node3D);

public:
    // GPU-side entity representation. 32 bytes, tightly packed.
    // Must match the struct layout in entity_movement.glsl.
    struct GPUEntity
    {
        int position[3];   // grid position xyz
        int state;         // packed: entity_type(8) | current_state(8) | carry_type(8) | health(8)
        int target[3];     // move target xyz
        int flags;         // packed: last_move_dir(3) | stuck_counter(4) | blocked_by_entity(1) | flow_snapshot(8) | squad_id(16)
    };

    EntityManager() {};
    ~EntityManager() {};

    void init(RenderingDevice *rd, VoxelWorldRIDs &voxel_world_rids, Vector3i world_size, float scale);
    void update(float delta);

    // GDScript API
    int spawn_entity(const Vector3i &position, const Vector3i &target);
    void set_entity_target(int id, const Vector3i &target);
    void set_flow_field_target(const Vector3i &target);
    void debug_draw_flow_field(int y_level);
    void debug_clear_flow_field(int y_level);
    void remove_entity(int id);
    int get_entity_count() const;
    Vector3i get_entity_position(int id) const;

protected:
    static void _bind_methods();

private:
    void _on_positions_updated(const PackedByteArray &data);

    static constexpr int MAX_ENTITIES = 2048;
    // Buffer layout: [active_count (4 bytes) | padding (28 bytes) | entities (32 bytes each)]
    // The 32-byte alignment for the first entity ensures GPU struct alignment.
    static constexpr int BUFFER_HEADER_SIZE = 32; // 1 uint active_count + 7 uint padding
    static constexpr int ENTITY_STRIDE = 32;      // sizeof(GPUEntity)
    static constexpr int BUFFER_CAPACITY = BUFFER_HEADER_SIZE + MAX_ENTITIES * ENTITY_STRIDE;

    ComputeShader *_movement_shader = nullptr;
    FlowField _flow_field;
    RenderingDevice *_rd = nullptr;
    RID _entity_buffer_rid;

    std::vector<GPUEntity> _entities;
    int _active_count = 0;
    bool _buffer_dirty = false;
    bool _is_readback_pending = false;

    Vector3i _world_size;
    float _scale = 0.125f;

    PackedByteArray _build_gpu_buffer() const;
    void _upload_full_buffer();
};

#endif // ENTITY_MANAGER_H
