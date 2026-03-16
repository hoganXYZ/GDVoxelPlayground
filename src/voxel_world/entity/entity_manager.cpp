#include "entity_manager.h"
#include <godot_cpp/variant/utility_functions.hpp>
#include <cmath>
#include <cstring>

using namespace godot;

void EntityManager::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("_on_positions_updated", "data"), &EntityManager::_on_positions_updated);

    ClassDB::bind_method(D_METHOD("spawn_entity", "position", "target"), &EntityManager::spawn_entity);
    ClassDB::bind_method(D_METHOD("set_entity_target", "id", "target"), &EntityManager::set_entity_target);
    ClassDB::bind_method(D_METHOD("set_flow_field_target", "target"), &EntityManager::set_flow_field_target);
    ClassDB::bind_method(D_METHOD("debug_draw_flow_field", "y_level"), &EntityManager::debug_draw_flow_field);
    ClassDB::bind_method(D_METHOD("debug_clear_flow_field", "y_level"), &EntityManager::debug_clear_flow_field);
    ClassDB::bind_method(D_METHOD("remove_entity", "id"), &EntityManager::remove_entity);
    ClassDB::bind_method(D_METHOD("get_entity_count"), &EntityManager::get_entity_count);
    ClassDB::bind_method(D_METHOD("get_entity_position", "id"), &EntityManager::get_entity_position);
}

void EntityManager::init(RenderingDevice *rd, VoxelWorldRIDs &voxel_world_rids, Vector3i world_size, float scale)
{
    _rd = rd;
    _world_size = world_size;
    _scale = scale;
    _active_count = 0;
    _entities.clear();
    _entities.reserve(MAX_ENTITIES);

    // Initialize flow field first so we can bind its buffer to the movement shader
    _flow_field.init(rd, voxel_world_rids, world_size);

    _movement_shader = new ComputeShader(
        "res://addons/voxel_playground/src/shaders/entity/entity_movement.glsl", rd);
    voxel_world_rids.add_voxel_buffers(_movement_shader);

    // Pre-allocate entity buffer (header + max entities)
    PackedByteArray empty_buffer;
    empty_buffer.resize(BUFFER_CAPACITY);
    memset(empty_buffer.ptrw(), 0, BUFFER_CAPACITY);
    _entity_buffer_rid = _movement_shader->create_storage_buffer_uniform(empty_buffer, 0, 1);

    // Bind flow field distance buffer to movement shader (set 1, binding 1)
    _movement_shader->add_existing_buffer(
        _flow_field.get_distance_buffer_rid(), RenderingDevice::UNIFORM_TYPE_STORAGE_BUFFER, 1, 1);

    _movement_shader->finish_create_uniforms();

    _buffer_dirty = false;
    _is_readback_pending = false;
}

void EntityManager::update(float delta)
{
    if (_movement_shader == nullptr || _active_count == 0)
        return;

    // Upload entity data if anything changed (spawn, target change, remove)
    if (_buffer_dirty)
    {
        _upload_full_buffer();
        _buffer_dirty = false;
    }

    // Dispatch: 1 thread per entity, 64 threads per group
    int group_count_x = std::max(1, (int)std::ceil((float)_active_count / 64.0f));
    _movement_shader->compute(Vector3i(group_count_x, 1, 1), false);

    // Async readback to sync positions from GPU
    if (!_is_readback_pending)
    {
        _is_readback_pending = true;
        _movement_shader->get_storage_buffer_uniform_async(
            _entity_buffer_rid, Callable(this, "_on_positions_updated"));
    }
}

void EntityManager::_on_positions_updated(const PackedByteArray &data)
{
    _is_readback_pending = false;

    if (data.size() < BUFFER_HEADER_SIZE)
        return;

    // Read back updated entity positions from GPU
    const uint8_t *ptr = data.ptr();
    int count = std::min(_active_count, (int)_entities.size());

    for (int i = 0; i < count; i++)
    {
        int offset = BUFFER_HEADER_SIZE + i * ENTITY_STRIDE;
        if (offset + ENTITY_STRIDE > data.size())
            break;

        const GPUEntity *gpu_entity = reinterpret_cast<const GPUEntity *>(ptr + offset);
        // Update CPU mirror position (GPU may have moved the entity)
        _entities[i].position[0] = gpu_entity->position[0];
        _entities[i].position[1] = gpu_entity->position[1];
        _entities[i].position[2] = gpu_entity->position[2];
        _entities[i].state = gpu_entity->state;
    }
}

int EntityManager::spawn_entity(const Vector3i &position, const Vector3i &target)
{
    if (_active_count >= MAX_ENTITIES)
    {
        UtilityFunctions::printerr("EntityManager: max entity count reached (", MAX_ENTITIES, ")");
        return -1;
    }

    GPUEntity entity = {};
    entity.position[0] = position.x;
    entity.position[1] = position.y;
    entity.position[2] = position.z;
    entity.state = (Voxel::VOXEL_TYPE_ENTITY << 24) | (1 << 16) | 0xFF; // type | state=moving | health=255
    entity.target[0] = target.x;
    entity.target[1] = target.y;
    entity.target[2] = target.z;
    entity.flags = (0xFF << 8); // flow_snapshot = 0xFF (uninitialized sentinel)

    int id = _active_count;
    _entities.push_back(entity);
    _active_count++;
    _buffer_dirty = true;

    return id;
}

void EntityManager::set_entity_target(int id, const Vector3i &target)
{
    if (id < 0 || id >= _active_count)
        return;

    _entities[id].target[0] = target.x;
    _entities[id].target[1] = target.y;
    _entities[id].target[2] = target.z;
    _buffer_dirty = true;
}

void EntityManager::set_flow_field_target(const Vector3i &target)
{
    _flow_field.compute(target);

    // Also update all entity targets so the GPU has a fallback
    for (int i = 0; i < _active_count; i++)
    {
        _entities[i].target[0] = target.x;
        _entities[i].target[1] = target.y;
        _entities[i].target[2] = target.z;
        // Reset stuck tracking fields (flow distances changed, old snapshots are stale)
        // Preserves squad_id (bits 16-31) + last_move_dir (bits 0-2), resets stuck/blocked/snapshot
        _entities[i].flags = (_entities[i].flags & 0xFFFF0007) | (0xFF << 8);
    }
    _buffer_dirty = true;
}

void EntityManager::debug_draw_flow_field(int y_level)
{
    _flow_field.debug_draw(y_level);
}

void EntityManager::debug_clear_flow_field(int y_level)
{
    _flow_field.debug_clear(y_level);
}

void EntityManager::remove_entity(int id)
{
    if (id < 0 || id >= _active_count)
        return;

    // Swap with last entity to keep array packed
    if (id < _active_count - 1)
    {
        _entities[id] = _entities[_active_count - 1];
    }
    _entities.pop_back();
    _active_count--;
    _buffer_dirty = true;
}

int EntityManager::get_entity_count() const
{
    return _active_count;
}

Vector3i EntityManager::get_entity_position(int id) const
{
    if (id < 0 || id >= _active_count)
        return Vector3i(-1, -1, -1);

    return Vector3i(_entities[id].position[0], _entities[id].position[1], _entities[id].position[2]);
}

PackedByteArray EntityManager::_build_gpu_buffer() const
{
    PackedByteArray buffer;
    buffer.resize(BUFFER_HEADER_SIZE + _active_count * ENTITY_STRIDE);
    uint8_t *ptr = buffer.ptrw();
    memset(ptr, 0, buffer.size());

    // Header: active_count as uint32
    uint32_t count = static_cast<uint32_t>(_active_count);
    memcpy(ptr, &count, sizeof(uint32_t));

    // Entity data
    for (int i = 0; i < _active_count; i++)
    {
        memcpy(ptr + BUFFER_HEADER_SIZE + i * ENTITY_STRIDE, &_entities[i], ENTITY_STRIDE);
    }

    return buffer;
}

void EntityManager::_upload_full_buffer()
{
    if (_movement_shader == nullptr)
        return;

    PackedByteArray buffer = _build_gpu_buffer();
    _movement_shader->update_storage_buffer_uniform(_entity_buffer_rid, buffer);
}
