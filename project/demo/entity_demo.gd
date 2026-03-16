extends Node3D

@export var voxel_world: VoxelWorld
@export var entity_manager: EntityManager
@export var spawn_count: int = 20
@export var spawn_height_offset: int = 5

var _spawned := false
var _debug_flow_field := false
var _debug_y_level := -1

func _ready() -> void:
	# Wait a frame for VoxelWorld to initialize
	await get_tree().process_frame
	await get_tree().process_frame
	if entity_manager and voxel_world and voxel_world.is_initialized():
		_spawn_initial_entities()

func _spawn_initial_entities() -> void:
	if _spawned:
		return
	_spawned = true

	var world_size := voxel_world.brick_map_size * Vector3i(8, 8, 8)
	var center := world_size / 2

	for i in range(spawn_count):
		# Spread entities in a cluster near the world center, above the terrain
		var offset := Vector3(
			randf_range(-10.0, 10.0),
			0.0,
			randf_range(-10.0, 10.0)
		)
		var pos := Vector3(center) + offset
		pos.y = float(center.y + spawn_height_offset)

		# Target: wander toward center of the world (stays Vector3i for flow field)
		var target := center + Vector3i(
			randi_range(-20, 20),
			randi_range(-5, 5),
			randi_range(-20, 20)
		)

		var id := entity_manager.spawn_entity(pos, target)
		if id >= 0:
			print("Spawned entity ", id, " at ", pos)

	print("Spawned ", entity_manager.get_entity_count(), " entities")

func _process(_delta: float) -> void:
	if not entity_manager or not voxel_world:
		return

	# Poll right-click here because _unhandled_input never sees mouse events
	# (player_controller's _input consumes them for camera look)
	if Input.is_action_just_pressed("right_click"):
		_set_targets_to_raycast()

func _unhandled_key_input(event: InputEvent) -> void:
	if not entity_manager or not voxel_world:
		return

	# Press E to spawn a batch of entities
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_E:
		_spawn_batch_at_player()

	# Press F to toggle flow field debug visualization at player Y-level
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F:
		_toggle_flow_field_debug()

func _spawn_batch_at_player() -> void:
	var player := get_node_or_null("../Player")
	if not player:
		return

	var grid_pos = player.global_position / voxel_world.scale

	for i in range(50):
		var offset := Vector3(randf_range(-3.0, 3.0), 2.0, randf_range(-3.0, 3.0))
		var pos = grid_pos + offset
		var target := Vector3i(grid_pos) + Vector3i(randi_range(-15, 15), 0, randi_range(-15, 15))
		entity_manager.spawn_entity(pos, target)

	print("Entity count: ", entity_manager.get_entity_count())

func _toggle_flow_field_debug() -> void:
	var player := get_node_or_null("../Player")
	if not player:
		return

	if _debug_flow_field:
		# Clear previous debug markers
		if _debug_y_level >= 0:
			entity_manager.debug_clear_flow_field(_debug_y_level)
		_debug_flow_field = false
		print("Flow field debug: OFF")
	else:
		# Clear old markers if any
		if _debug_y_level >= 0:
			entity_manager.debug_clear_flow_field(_debug_y_level)
		# Draw at player's Y level
		_debug_y_level = int(player.global_position.y / voxel_world.scale)
		entity_manager.debug_draw_flow_field(_debug_y_level)
		_debug_flow_field = true
		print("Flow field debug: ON at y=", _debug_y_level)

func _set_targets_to_raycast() -> void:
	var camera := get_viewport().get_camera_3d()
	if not camera:
		return

	var origin := camera.global_position
	var direction := -camera.global_transform.basis.z
	var hit := voxel_world.raycast_world(origin, direction, 200.0)


	if hit != Vector3(-1, -1, -1):
		var grid_target := Vector3i(hit)  # raycast already returns grid coordinates
		# Offset target up by 1 so entities don't try to enter terrain
		grid_target.y += 1
		# Clear old debug markers before recomputing flow field
		if _debug_flow_field and _debug_y_level >= 0:
			entity_manager.debug_clear_flow_field(_debug_y_level)

		entity_manager.set_flow_field_target(grid_target)
		print("Set flow field target to ", grid_target, " for ", entity_manager.get_entity_count(), " entities")

		# Redraw debug visualization if enabled
		if _debug_flow_field and _debug_y_level >= 0:
			entity_manager.debug_draw_flow_field(_debug_y_level)
