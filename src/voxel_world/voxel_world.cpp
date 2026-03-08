
#include "voxel_world.h"
#include "voxel_world_generator.h"
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

VoxelWorld::VoxelWorld()
{
    brick_map_size = Vector3i(16, 16, 16);
    scale = 0.125f;
    _initialized = false;
}

VoxelWorld::~VoxelWorld()
{

}

void VoxelWorld::edit_world(const Vector3 &camera_origin, const Vector3 &camera_direction, const float radius,
                            const float range, const int value)
{
    if (_edit_pass == nullptr)
        return;
    _edit_pass->edit_using_raycast(camera_origin, camera_direction, radius, range, value);
}

void VoxelWorld::edit_world_smooth(const Vector3 &camera_origin, const Vector3 &camera_direction, const float radius,
                                    const float range)
{
    if (_smooth_edit_pass == nullptr)
        return;
    _smooth_edit_pass->edit_using_raycast(camera_origin, camera_direction, radius, range, 0);
}

Vector3 VoxelWorld::raycast_world(const Vector3 &camera_origin, const Vector3 &camera_direction, const float range)
{
    if (_edit_pass == nullptr)
        return Vector3(-1, -1, -1);
    return _edit_pass->raycast(camera_origin, camera_direction, range);
}

void VoxelWorld::set_brush_preview(const Vector3 &position, const float radius)
{
    _voxel_properties.brush_preview_position = Vector4(position.x, position.y, position.z, 1.0f);
    _voxel_properties.brush_preview_radius = radius;
}

void VoxelWorld::clear_brush_preview()
{
    _voxel_properties.brush_preview_position = Vector4(0, 0, 0, -1.0f);
    _voxel_properties.brush_preview_radius = 0.0f;
}

void VoxelWorld::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("get_generator"), &VoxelWorld::get_generator);
    ClassDB::bind_method(D_METHOD("set_generator", "generator"), &VoxelWorld::set_generator);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "generator", PROPERTY_HINT_RESOURCE_TYPE, "VoxelWorldGenerator"),
                 "set_generator", "get_generator");

    ClassDB::bind_method(D_METHOD("get_brick_map_size"), &VoxelWorld::get_brick_map_size);
    ClassDB::bind_method(D_METHOD("set_brick_map_size", "brick_map_size"), &VoxelWorld::set_brick_map_size);
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR3I, "brick_map_size"), "set_brick_map_size", "get_brick_map_size");

    ClassDB::bind_method(D_METHOD("get_scale"), &VoxelWorld::get_scale);
    ClassDB::bind_method(D_METHOD("set_scale", "scale"), &VoxelWorld::set_scale);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "scale"), "set_scale", "get_scale");

    ClassDB::bind_method(D_METHOD("get_simulation_enabled"), &VoxelWorld::get_simulation_enabled);
    ClassDB::bind_method(D_METHOD("set_simulation_enabled", "enabled"), &VoxelWorld::set_simulation_enabled);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "simulation_enabled"), "set_simulation_enabled", "get_simulation_enabled");

    ClassDB::bind_method(D_METHOD("set_voxel_world_collider", "collider"), &VoxelWorld::set_voxel_world_collider);
    ClassDB::bind_method(D_METHOD("get_voxel_world_collider"), &VoxelWorld::get_voxel_world_collider);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "voxel_world_collider", PROPERTY_HINT_NODE_TYPE, "VoxelWorldCollider"),
                 "set_voxel_world_collider", "get_voxel_world_collider");

    ClassDB::bind_method(D_METHOD("get_player_node"), &VoxelWorld::get_player_node);
    ClassDB::bind_method(D_METHOD("set_player_node", "player_node"), &VoxelWorld::set_player_node);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "player_node", PROPERTY_HINT_NODE_TYPE, "Node3D"), "set_player_node",
                 "get_player_node");

    ClassDB::bind_method(D_METHOD("get_sun_light"), &VoxelWorld::get_sun_light);
    ClassDB::bind_method(D_METHOD("set_sun_light", "sun_light"), &VoxelWorld::set_sun_light);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "sun_light", PROPERTY_HINT_NODE_TYPE, "DirectionalLight3D"),
                 "set_sun_light", "get_sun_light");

    ClassDB::bind_method(D_METHOD("get_ground_color"), &VoxelWorld::get_ground_color);
    ClassDB::bind_method(D_METHOD("set_ground_color", "ground_color"), &VoxelWorld::set_ground_color);
    ADD_PROPERTY(PropertyInfo(Variant::COLOR, "ground_color"), "set_ground_color", "get_ground_color");

    ClassDB::bind_method(D_METHOD("get_sky_color"), &VoxelWorld::get_sky_color);
    ClassDB::bind_method(D_METHOD("set_sky_color", "sky_color"), &VoxelWorld::set_sky_color);
    ADD_PROPERTY(PropertyInfo(Variant::COLOR, "sky_color"), "set_sky_color", "get_sky_color");

    // CellPond rules
    ClassDB::bind_method(D_METHOD("get_cellpond_rules"), &VoxelWorld::get_cellpond_rules);
    ClassDB::bind_method(D_METHOD("set_cellpond_rules", "rules"), &VoxelWorld::set_cellpond_rules);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "cellpond_rules", PROPERTY_HINT_RESOURCE_TYPE, "CellPondRuleSet"),
                 "set_cellpond_rules", "get_cellpond_rules");

    // Generation controls
    ClassDB::bind_method(D_METHOD("get_auto_update_generation"), &VoxelWorld::get_auto_update_generation);
    ClassDB::bind_method(D_METHOD("set_auto_update_generation", "enabled"), &VoxelWorld::set_auto_update_generation);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "auto_update_generation"), "set_auto_update_generation", "get_auto_update_generation");

    ClassDB::bind_method(D_METHOD("update_generation"), &VoxelWorld::update_generation);
    ADD_PROPERTY(PropertyInfo(Variant::NIL, "update_generation", PROPERTY_HINT_TOOL_BUTTON, "Update Generation"), "", "update_generation");

    ClassDB::bind_method(D_METHOD("upload_cellpond_rules"), &VoxelWorld::upload_cellpond_rules);
    ClassDB::bind_method(D_METHOD("get_voxel_at", "grid_pos"), &VoxelWorld::get_voxel_at);

    ClassDB::bind_method(D_METHOD("get_properties_rid"), &VoxelWorld::get_properties_rid);
    ClassDB::bind_method(D_METHOD("get_voxel_bricks_rid"), &VoxelWorld::get_voxel_bricks_rid);
    ClassDB::bind_method(D_METHOD("get_voxel_data_rid"), &VoxelWorld::get_voxel_data_rid);
    ClassDB::bind_method(D_METHOD("get_voxel_data2_rid"), &VoxelWorld::get_voxel_data2_rid);
    ClassDB::bind_method(D_METHOD("is_initialized"), &VoxelWorld::is_initialized);

    // methods
    ClassDB::bind_method(D_METHOD("edit_world", "camera_origin", "camera_direction", "radius", "range", "value"),
                         &VoxelWorld::edit_world);
    ClassDB::bind_method(D_METHOD("edit_world_smooth", "camera_origin", "camera_direction", "radius", "range"),
                         &VoxelWorld::edit_world_smooth);
    ClassDB::bind_method(D_METHOD("raycast_world", "camera_origin", "camera_direction", "range"),
                         &VoxelWorld::raycast_world);
    ClassDB::bind_method(D_METHOD("set_brush_preview", "position", "radius"),
                         &VoxelWorld::set_brush_preview);
    ClassDB::bind_method(D_METHOD("clear_brush_preview"),
                         &VoxelWorld::clear_brush_preview);
}

void VoxelWorld::_notification(int p_what)
{
    bool in_editor = godot::Engine::get_singleton()->is_editor_hint();

    switch (p_what)
    {
    case NOTIFICATION_ENTER_TREE: {
        if (!in_editor)
            set_physics_process_internal(true);
        break;
    }
    case NOTIFICATION_EXIT_TREE: {
        set_physics_process_internal(false);
        break;
    }
    case NOTIFICATION_READY: {
        init();
        break;
    }
    case NOTIFICATION_INTERNAL_PHYSICS_PROCESS: {
        if (in_editor)
            return;
        float delta = get_physics_process_delta_time();
        update(delta);
        break;
    }
    }
}

void VoxelWorld::init()
{
    Vector3i size = brick_map_size * BRICK_SIZE;

    _voxel_properties = VoxelWorldProperties(size, brick_map_size, scale);
    _voxel_properties.set_sky_colors(sky_color, ground_color);
    if (_sun_light != nullptr)
        _voxel_properties.set_sun(_sun_light->get_color(), -_sun_light->get_global_transform().basis.rows[2]);
    _voxel_properties.frame = 0;
    _rd = RenderingServer::get_singleton()->get_rendering_device();
    _voxel_world_rids.rendering_device = _rd;

    // create grid buffer
    PackedByteArray voxel_bricks;
    int brick_count = brick_map_size.x * brick_map_size.y * brick_map_size.z;
    voxel_bricks.resize(brick_count * sizeof(Brick));
    _voxel_world_rids.voxel_bricks = _rd->storage_buffer_create(voxel_bricks.size(), voxel_bricks);
    _voxel_world_rids.brick_count = brick_count;

    // Create the voxel data buffer.
    PackedByteArray voxel_data;
    int voxel_count = size.x * size.y * size.z;
    if (voxel_count * sizeof(Voxel) > 4.0e9f)
    {
        UtilityFunctions::printerr(
            "VoxelWorld: The voxel world is too large (exceeds 4GB, or 2 billion voxels). Reduce the brick map size.");
        return;
    }
    voxel_data.resize(voxel_count * sizeof(Voxel));
    _voxel_world_rids.voxel_data = _rd->storage_buffer_create(voxel_data.size(), voxel_data);
    _voxel_world_rids.voxel_data2 = _rd->storage_buffer_create(voxel_data.size(), voxel_data); //create a second to facilitate ping-pong buffers
    _voxel_world_rids.voxel_count = voxel_count;

    // Create the voxel properties buffer.
    PackedByteArray properties_data = _voxel_properties.to_packed_byte_array();
    _voxel_world_rids.properties = _rd->storage_buffer_create(properties_data.size(), properties_data);

    if (generator.is_null())
    {
        UtilityFunctions::printerr(
            "VoxelWorld: No world generator set.");
        return;
    }
    generator->initialize_brick_grid(_rd, _voxel_world_rids, _voxel_properties);
    generator->generate(_rd, _voxel_world_rids, _voxel_properties);

    // Create the update pass.
    _update_pass = new VoxelWorldUpdatePass("res://addons/voxel_playground/src/shaders/automata/liquid.glsl", _rd, _voxel_world_rids, size);

    // Run cleanup once to compute brick occupancy after generation
    _update_pass->run_cleanup();

    // Create the CellPond rule pass.
    _cellpond_pass = new CellPondUpdatePass(_rd, _voxel_world_rids, size);
    if (_cellpond_rules.is_valid())
    {
        _cellpond_pass->set_rules(_cellpond_rules->build_gpu_buffer());
    }

    // Create the edit passes.
    _edit_pass = new VoxelEditPass("res://addons/voxel_playground/src/shaders/voxel_edit/sphere_edit.glsl", _rd, _voxel_world_rids, size);
    _smooth_edit_pass = new VoxelEditPass("res://addons/voxel_playground/src/shaders/voxel_edit/smooth_edit.glsl", _rd, _voxel_world_rids, size);

    // if collider set, initialize it
    if (_voxel_world_collider != nullptr)
    {
        _voxel_world_collider->init(_rd, _voxel_world_rids, scale);
    }
    
    _initialized = true;
}

void VoxelWorld::update(float delta)
{
    if(!_initialized) 
        return;
    _voxel_properties.frame++;
    PackedByteArray properties_data = _voxel_properties.to_packed_byte_array();
    _rd->buffer_update(_voxel_world_rids.properties, 0, properties_data.size(), properties_data);

    if (simulation_enabled)
    {
        _update_pass->update(delta);
    }

    if (_cellpond_pass != nullptr)
    {
        _cellpond_pass->update(delta);
    }

    if (_voxel_world_collider != nullptr && player_node != nullptr)
    {
        _voxel_world_collider->update(get_voxel_world_position(player_node->get_global_position()));
    }
}

void VoxelWorld::upload_cellpond_rules()
{
    if (_cellpond_pass == nullptr || _cellpond_rules.is_null())
        return;
    _cellpond_pass->set_rules(_cellpond_rules->build_gpu_buffer());
}

void VoxelWorld::update_generation()
{
    if (!_initialized || generator.is_null() || _rd == nullptr)
        return;

    generator->generate(_rd, _voxel_world_rids, _voxel_properties);

    if (_update_pass != nullptr)
        _update_pass->run_cleanup();
}

Dictionary VoxelWorld::get_voxel_at(const Vector3i &grid_pos)
{
    Dictionary result;
    result["type"] = 0;
    result["color"] = Color(0, 0, 0);

    if (!_initialized || _rd == nullptr)
        return result;

    if (!_voxel_properties.isValidPos(grid_pos))
        return result;

    unsigned int voxel_index = _voxel_properties.pos_to_voxel_index(grid_pos);

    // Read the voxel data from GPU - read the current buffer based on frame parity
    RID buffer_rid = (_voxel_properties.frame % 2 == 0) ? _voxel_world_rids.voxel_data : _voxel_world_rids.voxel_data2;
    PackedByteArray data = _rd->buffer_get_data(buffer_rid, voxel_index * sizeof(Voxel), sizeof(Voxel));

    if (data.size() >= static_cast<int>(sizeof(Voxel)))
    {
        Voxel v;
        std::memcpy(&v, data.ptr(), sizeof(Voxel));
        result["type"] = v.get_type();
        result["color"] = v.get_color();
    }

    return result;
}
