
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

void VoxelWorld::edit_world_at(const Vector3 &grid_position, const float radius, const int value)
{
    if (_edit_pass == nullptr)
        return;
    _edit_pass->edit_at(grid_position, radius, value);
}

void VoxelWorld::add_explosion(const Vector3 &grid_center, const float radius, const float strength)
{
    if ((int)_pending_explosions.size() >= VoxelWorldRIDs::MAX_EXPLOSIONS_PER_TICK)
    {
        UtilityFunctions::printerr("VoxelWorld::add_explosion(): explosion queue full (16/tick), dropping.");
        return;
    }
    GpuExplosion e;
    e.cx = grid_center.x;
    e.cy = grid_center.y;
    e.cz = grid_center.z;
    e.radius = MAX(radius, 1.0f);
    e.strength = strength;
    _pending_explosions.push_back(e);
}

void VoxelWorld::project_texture(const RID &texture, const Vector2i &texture_size,
                                 const Projection &inv_view_projection, const Vector3 &origin, const int value,
                                 const Color &tint, const float alpha_threshold, const float max_range,
                                 const bool place_on_surface)
{
    if (_projector_pass == nullptr)
        return;
    _projector_pass->project(texture, texture_size, inv_view_projection, origin, value, tint, alpha_threshold,
                             max_range, place_on_surface);
}

void VoxelWorld::project_texture_parallel(const RID &texture, const Vector2i &texture_size, const Vector3 &origin,
                                          const Vector3 &right_extent, const Vector3 &up_extent,
                                          const Vector3 &direction, const int value, const Color &tint,
                                          const float alpha_threshold, const float max_range,
                                          const bool place_on_surface)
{
    if (_projector_pass == nullptr)
        return;
    _projector_pass->project_parallel(texture, texture_size, origin, right_extent, up_extent, direction, value, tint,
                                      alpha_threshold, max_range, place_on_surface);
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

    ClassDB::bind_method(D_METHOD("set_entity_manager", "manager"), &VoxelWorld::set_entity_manager);
    ClassDB::bind_method(D_METHOD("get_entity_manager"), &VoxelWorld::get_entity_manager);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "entity_manager", PROPERTY_HINT_NODE_TYPE, "EntityManager"),
                 "set_entity_manager", "get_entity_manager");

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

    // Element system
    ClassDB::bind_method(D_METHOD("get_element_set"), &VoxelWorld::get_element_set);
    ClassDB::bind_method(D_METHOD("set_element_set", "element_set"), &VoxelWorld::set_element_set);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "element_set", PROPERTY_HINT_RESOURCE_TYPE, "VoxelElementSet"),
                 "set_element_set", "get_element_set");
    ClassDB::bind_method(D_METHOD("upload_elements"), &VoxelWorld::upload_elements);

    // Generation controls
    ClassDB::bind_method(D_METHOD("get_auto_update_generation"), &VoxelWorld::get_auto_update_generation);
    ClassDB::bind_method(D_METHOD("set_auto_update_generation", "enabled"), &VoxelWorld::set_auto_update_generation);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "auto_update_generation"), "set_auto_update_generation", "get_auto_update_generation");

    ClassDB::bind_method(D_METHOD("update_generation"), &VoxelWorld::update_generation);
    ADD_PROPERTY(PropertyInfo(Variant::NIL, "update_generation", PROPERTY_HINT_TOOL_BUTTON, "Update Generation"), "", "update_generation");

    ClassDB::bind_method(D_METHOD("upload_cellpond_rules"), &VoxelWorld::upload_cellpond_rules);
    ClassDB::bind_method(D_METHOD("get_voxel_at", "grid_pos"), &VoxelWorld::get_voxel_at);
    ClassDB::bind_method(D_METHOD("census_box", "box_min", "box_max", "type_id"), &VoxelWorld::census_box);

    ClassDB::bind_method(D_METHOD("get_properties_rid"), &VoxelWorld::get_properties_rid);
    ClassDB::bind_method(D_METHOD("get_voxel_bricks_rid"), &VoxelWorld::get_voxel_bricks_rid);
    ClassDB::bind_method(D_METHOD("get_voxel_data_rid"), &VoxelWorld::get_voxel_data_rid);
    ClassDB::bind_method(D_METHOD("get_voxel_data2_rid"), &VoxelWorld::get_voxel_data2_rid);
    ClassDB::bind_method(D_METHOD("is_initialized"), &VoxelWorld::is_initialized);
    ClassDB::bind_method(D_METHOD("get_init_version"), &VoxelWorld::get_init_version);
    ClassDB::bind_method(D_METHOD("reinit"), &VoxelWorld::reinit);

    // methods
    ClassDB::bind_method(D_METHOD("edit_world", "camera_origin", "camera_direction", "radius", "range", "value"),
                         &VoxelWorld::edit_world);
    ClassDB::bind_method(D_METHOD("edit_world_smooth", "camera_origin", "camera_direction", "radius", "range"),
                         &VoxelWorld::edit_world_smooth);
    ClassDB::bind_method(D_METHOD("edit_world_at", "grid_position", "radius", "value"),
                         &VoxelWorld::edit_world_at);
    ClassDB::bind_method(D_METHOD("add_explosion", "grid_center", "radius", "strength"),
                         &VoxelWorld::add_explosion);
    ClassDB::bind_method(D_METHOD("raycast_world", "camera_origin", "camera_direction", "range"),
                         &VoxelWorld::raycast_world);
    ClassDB::bind_method(D_METHOD("project_texture", "texture", "texture_size", "inv_view_projection", "origin",
                                  "value", "tint", "alpha_threshold", "max_range", "place_on_surface"),
                         &VoxelWorld::project_texture, DEFVAL(Color(1, 1, 1)), DEFVAL(0.5f), DEFVAL(1000.0f),
                         DEFVAL(false));
    ClassDB::bind_method(D_METHOD("project_texture_parallel", "texture", "texture_size", "origin", "right_extent",
                                  "up_extent", "direction", "value", "tint", "alpha_threshold", "max_range",
                                  "place_on_surface"),
                         &VoxelWorld::project_texture_parallel, DEFVAL(Color(1, 1, 1)), DEFVAL(0.5f),
                         DEFVAL(1000.0f), DEFVAL(false));
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

void VoxelWorld::set_brick_map_size(const Vector3i &p_size)
{
    brick_map_size = p_size.clamp(Vector3i(0,0,0), Vector3i(256,256,256));
    if (_initialized)
        reinit();
}

void VoxelWorld::cleanup()
{
    if (!_initialized || _rd == nullptr)
        return;

    delete _update_pass;     _update_pass = nullptr;
    delete _cellpond_pass;   _cellpond_pass = nullptr;
    delete _edit_pass;       _edit_pass = nullptr;
    delete _smooth_edit_pass; _smooth_edit_pass = nullptr;
    delete _projector_pass;  _projector_pass = nullptr;

    if (_voxel_world_rids.voxel_bricks.is_valid())
        _rd->free_rid(_voxel_world_rids.voxel_bricks);
    if (_voxel_world_rids.voxel_data.is_valid())
        _rd->free_rid(_voxel_world_rids.voxel_data);
    if (_voxel_world_rids.voxel_data2.is_valid())
        _rd->free_rid(_voxel_world_rids.voxel_data2);
    if (_voxel_world_rids.properties.is_valid())
        _rd->free_rid(_voxel_world_rids.properties);
    if (_voxel_world_rids.point_lights.is_valid())
        _rd->free_rid(_voxel_world_rids.point_lights);
    if (_voxel_world_rids.element_table.is_valid())
        _rd->free_rid(_voxel_world_rids.element_table);
    if (_voxel_world_rids.reaction_rules.is_valid())
        _rd->free_rid(_voxel_world_rids.reaction_rules);
    if (_voxel_world_rids.voxel_aux.is_valid())
        _rd->free_rid(_voxel_world_rids.voxel_aux);
    if (_voxel_world_rids.voxel_aux2.is_valid())
        _rd->free_rid(_voxel_world_rids.voxel_aux2);
    if (_voxel_world_rids.behavior_ops.is_valid())
        _rd->free_rid(_voxel_world_rids.behavior_ops);
    if (_voxel_world_rids.voxel_dynamics.is_valid())
        _rd->free_rid(_voxel_world_rids.voxel_dynamics);
    if (_voxel_world_rids.voxel_dynamics2.is_valid())
        _rd->free_rid(_voxel_world_rids.voxel_dynamics2);
    if (_voxel_world_rids.explosions.is_valid())
        _rd->free_rid(_voxel_world_rids.explosions);

    _voxel_world_rids = VoxelWorldRIDs();
    _initialized = false;
}

void VoxelWorld::reinit()
{
    cleanup();
    init();
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

    // Create the point lights buffer (16-byte header with the light count,
    // then a fixed-capacity array; refreshed every frame from OmniLight3D children).
    {
        PackedByteArray light_data;
        light_data.resize(16 + VoxelWorldRIDs::MAX_POINT_LIGHTS * sizeof(GpuPointLight));
        _voxel_world_rids.point_lights = _rd->storage_buffer_create(light_data.size(), light_data);
    }

    // Create the CA table buffers (element defs, reaction rules, behavior ops)
    // and the per-voxel aux channel (temperature/life/flags, double-buffered).
    {
        PackedByteArray element_table;
        element_table.resize(VoxelElementSet::MAX_ELEMENTS * sizeof(GpuElementDef));
        _voxel_world_rids.element_table = _rd->storage_buffer_create(element_table.size(), element_table);

        PackedByteArray reaction_table;
        reaction_table.resize(VoxelElementSet::MAX_REACTION_RULES * sizeof(GpuReactionRule));
        _voxel_world_rids.reaction_rules = _rd->storage_buffer_create(reaction_table.size(), reaction_table);

        PackedByteArray behavior_table;
        behavior_table.resize(VoxelElementSet::MAX_BEHAVIOR_OPS * sizeof(GpuBehaviorOp));
        _voxel_world_rids.behavior_ops = _rd->storage_buffer_create(behavior_table.size(), behavior_table);

        // aux starts at ambient temperature everywhere
        PackedByteArray aux_data;
        aux_data.resize(voxel_count * sizeof(uint32_t));
        uint32_t *aux_ptr = reinterpret_cast<uint32_t *>(aux_data.ptrw());
        const uint32_t ambient = VoxelElementSet::quantize_temp(293.0f);
        for (int i = 0; i < voxel_count; i++)
            aux_ptr[i] = ambient;
        _voxel_world_rids.voxel_aux = _rd->storage_buffer_create(aux_data.size(), aux_data);
        _voxel_world_rids.voxel_aux2 = _rd->storage_buffer_create(aux_data.size(), aux_data);

        // per-voxel dynamics channel (velocity + freefall/particle flags),
        // double-buffered like aux and zero-initialized (at rest, no flags)
        PackedByteArray dynamics_data;
        dynamics_data.resize(voxel_count * sizeof(uint32_t));
        _voxel_world_rids.voxel_dynamics = _rd->storage_buffer_create(dynamics_data.size(), dynamics_data);
        _voxel_world_rids.voxel_dynamics2 = _rd->storage_buffer_create(dynamics_data.size(), dynamics_data);

        // explosion queue: 16-byte header {count, spark_id} + 16 entries
        PackedByteArray explosion_data;
        explosion_data.resize(16 + VoxelWorldRIDs::MAX_EXPLOSIONS_PER_TICK * sizeof(GpuExplosion));
        _voxel_world_rids.explosions = _rd->storage_buffer_create(explosion_data.size(), explosion_data);
    }

    if (_element_set.is_null())
        set_element_set(VoxelElementSet::create_default());
    upload_elements();

    if (generator.is_null())
    {
        UtilityFunctions::printerr(
            "VoxelWorld: No world generator set.");
        return;
    }
    generator->initialize_brick_grid(_rd, _voxel_world_rids, _voxel_properties);
    generator->generate(_rd, _voxel_world_rids, _voxel_properties);

    // Create the update pass (and its Tier-4 custom pass, compiled from the
    // element set's custom_glsl snippets).
    _update_pass = new VoxelWorldUpdatePass(_rd, _voxel_world_rids, size);
    _update_pass->set_custom_source(_element_set->build_custom_source());

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
    _projector_pass = new VoxelProjectorPass(_rd, _voxel_world_rids);

    // if collider set, initialize it
    if (_voxel_world_collider != nullptr)
    {
        _voxel_world_collider->init(_rd, _voxel_world_rids, scale);
    }

    // if entity manager set, initialize it
    if (_entity_manager != nullptr)
    {
        _entity_manager->init(_rd, _voxel_world_rids, size, scale);
    }

    _initialized = true;
    _init_version++;
}

void VoxelWorld::update(float delta)
{
    if(!_initialized)
        return;
    _voxel_properties.frame++;
    PackedByteArray properties_data = _voxel_properties.to_packed_byte_array();
    _rd->buffer_update(_voxel_world_rids.properties, 0, properties_data.size(), properties_data);

    update_point_lights();

    if (simulation_enabled)
    {
        // queued explosions edit the prev buffer right before movement reads it
        if (!_pending_explosions.empty() && _update_pass != nullptr)
        {
            int spark_id = _element_set.is_valid() ? _element_set->find_element_id("explosion_spark") : -1;
            if (spark_id < 0 && _element_set.is_valid())
                spark_id = _element_set->find_element_id("fire"); // decent stand-in
            PackedByteArray queue_data;
            queue_data.resize(16 + VoxelWorldRIDs::MAX_EXPLOSIONS_PER_TICK * sizeof(GpuExplosion));
            uint32_t *header = reinterpret_cast<uint32_t *>(queue_data.ptrw());
            header[0] = (uint32_t)_pending_explosions.size();
            header[1] = spark_id > 0 ? (uint32_t)spark_id : 0u;
            std::memcpy(queue_data.ptrw() + 16, _pending_explosions.data(),
                        _pending_explosions.size() * sizeof(GpuExplosion));
            _rd->buffer_update(_voxel_world_rids.explosions, 0, queue_data.size(), queue_data);
            _update_pass->run_explosions();
            _pending_explosions.clear();
        }

        // movement tick: read prev, write cur; cleanup erases the moved-away
        // dynamics from prev so it can be the write target of the next flip
        _update_pass->run_movement();
        _update_pass->run_cleanup();

        // reaction tick runs on its own buffer flip so every thread sees a
        // stable post-movement snapshot and writes only its own cell
        _voxel_properties.frame++;
        properties_data = _voxel_properties.to_packed_byte_array();
        _rd->buffer_update(_voxel_world_rids.properties, 0, properties_data.size(), properties_data);
        _update_pass->run_reactions();
        _update_pass->run_cleanup();
    }

    // Entity movement runs after automata but before cellpond
    if (_entity_manager != nullptr)
    {
        _entity_manager->update(delta);
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

void VoxelWorld::update_point_lights()
{
    if (!_initialized || _rd == nullptr || !_voxel_world_rids.point_lights.is_valid())
        return;

    TypedArray<Node> nodes = find_children("*", "OmniLight3D", true, false);
    int candidate_count = MIN(static_cast<int>(nodes.size()), VoxelWorldRIDs::MAX_POINT_LIGHTS);

    PackedByteArray data;
    data.resize(16 + VoxelWorldRIDs::MAX_POINT_LIGHTS * sizeof(GpuPointLight));
    GpuPointLight *lights = reinterpret_cast<GpuPointLight *>(data.ptrw() + 16);

    int light_count = 0;
    for (int i = 0; i < candidate_count; i++)
    {
        OmniLight3D *light = Object::cast_to<OmniLight3D>(nodes[i]);
        if (light == nullptr || !light->is_visible_in_tree())
            continue;
        Vector3 pos = light->get_global_position();
        Color color = light->get_color();
        float energy = light->get_param(Light3D::PARAM_ENERGY);
        lights[light_count].position = Vector4(pos.x, pos.y, pos.z, light->get_param(Light3D::PARAM_RANGE));
        lights[light_count].color = Vector4(color.r * energy, color.g * energy, color.b * energy,
                                            light->get_param(Light3D::PARAM_SIZE));
        light_count++;
    }
    reinterpret_cast<int32_t *>(data.ptrw())[0] = light_count;

    // header + only the lights actually written
    _rd->buffer_update(_voxel_world_rids.point_lights, 0, 16 + light_count * sizeof(GpuPointLight), data);
}

void VoxelWorld::set_element_set(const Ref<VoxelElementSet> &p_set)
{
    Callable upload = Callable(this, "upload_elements");
    if (_element_set.is_valid() && _element_set->is_connected("changed", upload))
        _element_set->disconnect("changed", upload);
    _element_set = p_set;
    if (_element_set.is_valid() && !_element_set->is_connected("changed", upload))
        _element_set->connect("changed", upload);
    if (_initialized)
        upload_elements();
}

void VoxelWorld::upload_elements()
{
    if (_rd == nullptr || _element_set.is_null() || !_voxel_world_rids.element_table.is_valid())
        return;

    PackedByteArray element_table, reaction_table, behavior_table;
    if (!_element_set->build_tables(element_table, reaction_table, behavior_table))
        return;

    _rd->buffer_update(_voxel_world_rids.element_table, 0, element_table.size(), element_table);
    _rd->buffer_update(_voxel_world_rids.reaction_rules, 0, reaction_table.size(), reaction_table);
    _rd->buffer_update(_voxel_world_rids.behavior_ops, 0, behavior_table.size(), behavior_table);

    // rebuild the Tier-4 custom pass if any custom_glsl changed (no-op otherwise)
    if (_update_pass != nullptr)
        _update_pass->set_custom_source(_element_set->build_custom_source());
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

Dictionary VoxelWorld::census_box(const Vector3i &box_min, const Vector3i &box_max, const int type_id)
{
    Dictionary result;
    result["count"] = 0;
    result["max_y"] = -1;
    result["min_y"] = 9999;

    if (!_initialized || _rd == nullptr)
        return result;

    // One whole-buffer readback instead of a synchronous buffer_get_data per
    // voxel — box scans from script (tests) otherwise stall the frame for
    // every single cell.
    RID buffer_rid = (_voxel_properties.frame % 2 == 0) ? _voxel_world_rids.voxel_data : _voxel_world_rids.voxel_data2;
    PackedByteArray data = _rd->buffer_get_data(buffer_rid);
    const Voxel *voxels = reinterpret_cast<const Voxel *>(data.ptr());
    const int64_t voxel_count = data.size() / sizeof(Voxel);

    int count = 0;
    int max_y = -1;
    int min_y = 9999;
    for (int x = box_min.x; x <= box_max.x; x++)
        for (int y = box_min.y; y <= box_max.y; y++)
            for (int z = box_min.z; z <= box_max.z; z++)
            {
                Vector3i p(x, y, z);
                if (!_voxel_properties.isValidPos(p))
                    continue;
                unsigned int idx = _voxel_properties.pos_to_voxel_index(p);
                if ((int64_t)idx >= voxel_count)
                    continue;
                if (voxels[idx].get_type() == type_id)
                {
                    count++;
                    max_y = MAX(max_y, y);
                    min_y = MIN(min_y, y);
                }
            }

    result["count"] = count;
    result["max_y"] = max_y;
    result["min_y"] = min_y;
    return result;
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
