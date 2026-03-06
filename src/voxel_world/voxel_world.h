#ifndef VOXEL_WORLD_H
#define VOXEL_WORLD_H

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/vector3i.hpp>
#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/directional_light3d.hpp>

#include "voxel_world/voxel_properties.h"
#include "voxel_world/cellular_automata/voxel_world_update_pass.h"
#include "voxel_world/cellular_automata/cellpond_update_pass.h"
#include "voxel_world/cellular_automata/cellpond_rule_set.h"
#include "voxel_world/voxel_edit/voxel_edit_pass.h"
#include "voxel_world/colliders/voxel_world_collider.h"
#include "voxel_world/generator/voxel_world_generator.h"

using namespace godot;

class VoxelWorld : public Node3D {
    GDCLASS(VoxelWorld, Node3D);

protected:
    static void _bind_methods();
    void _notification(int what);

private:
    // The size property will store the dimensions of your voxel world in terms of brick counts.
    const Vector3i BRICK_SIZE = Vector3i(8,8,8);
    Vector3i brick_map_size = Vector3i(16, 16, 16);
    float scale = 0.125f;
    bool simulation_enabled = true;
    bool _initialized;

    // RID _voxel_data_rid;
    // RID _voxel_bricks_rid;
    // RID _voxel_properties_rid;
    VoxelWorldRIDs _voxel_world_rids;
    VoxelWorldProperties _voxel_properties;
    RenderingDevice* _rd;
    Node3D* player_node = nullptr;

    Ref<VoxelWorldGenerator> generator;
    Ref<CellPondRuleSet> _cellpond_rules;
    VoxelWorldUpdatePass* _update_pass = nullptr;
    CellPondUpdatePass* _cellpond_pass = nullptr;
    VoxelEditPass* _edit_pass = nullptr;
    VoxelEditPass* _smooth_edit_pass = nullptr;
    VoxelWorldCollider* _voxel_world_collider = nullptr;

    DirectionalLight3D* _sun_light = nullptr;
    Color ground_color = Color(0.5, 0.3, 0.15, 1.0);
    Color sky_color = Color(1.0, 1.0, 1.0, 1.0);

    void init();
    void update(float delta);

    Vector3i get_voxel_world_position(const Vector3 &position) const {
        return Vector3i(std::floor(position.x / scale), std::floor(position.y / scale), std::floor(position.z / scale));
    }

public:
    VoxelWorld();
    ~VoxelWorld();    

    // Property accessors for size.
    void set_brick_map_size(const Vector3i &p_size) { brick_map_size = p_size.clamp(Vector3i(0,0,0), Vector3i(256,256,256)); }
    Vector3i get_brick_map_size() const { return brick_map_size; }

    void set_scale(float p_scale) { scale = p_scale; }
    float get_scale() const { return scale; }

    void set_simulation_enabled(bool enabled) { simulation_enabled = enabled; }
    bool get_simulation_enabled() const { return simulation_enabled; }

    void set_sun_light(DirectionalLight3D* node) { _sun_light = node; }
    DirectionalLight3D* get_sun_light() const { return _sun_light; }

    void set_ground_color(const Color &color) { ground_color = color; }
    Color get_ground_color() const { return ground_color; }
    void set_sky_color(const Color &color) { sky_color = color; }
    Color get_sky_color() const { return sky_color; }

    void set_player_node(Node3D* node) { player_node = node; }
    Node3D* get_player_node() const { return player_node; }

    void set_voxel_world_collider(VoxelWorldCollider* collider) {_voxel_world_collider = collider;}
    VoxelWorldCollider* get_voxel_world_collider() const { return _voxel_world_collider; }

    void edit_world(const Vector3 &camera_origin, const Vector3 &camera_direction, const float radius, const float range, const int value);
    void edit_world_smooth(const Vector3 &camera_origin, const Vector3 &camera_direction, const float radius, const float range);
    Vector3 raycast_world(const Vector3 &camera_origin, const Vector3 &camera_direction, const float range);
    void set_brush_preview(const Vector3 &position, const float radius);
    void clear_brush_preview();

    VoxelWorldRIDs get_voxel_world_rids() const { return _voxel_world_rids; }
    VoxelWorldProperties get_voxel_properties() const { return _voxel_properties; }

    RID get_properties_rid() const { return _voxel_world_rids.properties; }
    RID get_voxel_bricks_rid() const { return _voxel_world_rids.voxel_bricks; }
    RID get_voxel_data_rid() const { return _voxel_world_rids.voxel_data; }
    RID get_voxel_data2_rid() const { return _voxel_world_rids.voxel_data2; }
    bool is_initialized() const { return _initialized; }

    Ref<VoxelWorldGenerator> get_generator() const { return generator;}
    void set_generator(const Ref<VoxelWorldGenerator> p_generator) { generator = p_generator; }

    Ref<CellPondRuleSet> get_cellpond_rules() const { return _cellpond_rules; }
    void set_cellpond_rules(const Ref<CellPondRuleSet> p_rules) { _cellpond_rules = p_rules; }
    void upload_cellpond_rules();
    Dictionary get_voxel_at(const Vector3i &grid_pos);
};

#endif // VOXEL_WORLD_H
