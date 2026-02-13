
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

    // methods
    ClassDB::bind_method(D_METHOD("edit_world", "camera_origin", "camera_direction", "radius", "range", "value"),
                         &VoxelWorld::edit_world);
}

void VoxelWorld::_notification(int p_what)
{
    if (godot::Engine::get_singleton()->is_editor_hint())
    {
        return;
    }
    switch (p_what)
    {
    case NOTIFICATION_ENTER_TREE: {
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
            "VoxelWorld: The voxel world is too large (exceeds 4GB, or 1 billion voxels). Reduce the brick map size.");
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

    // Create the edit pass.
    _edit_pass = new VoxelEditPass("res://addons/voxel_playground/src/shaders/voxel_edit/sphere_edit.glsl", _rd, _voxel_world_rids, size);

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

    if (_voxel_world_collider != nullptr && player_node != nullptr)
    {
        _voxel_world_collider->update(get_voxel_world_position(player_node->get_global_position()));
    }
}
