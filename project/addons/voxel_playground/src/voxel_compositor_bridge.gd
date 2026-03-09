@tool
extends Node
class_name VoxelCompositorBridge

## Connects a VoxelWorld node to a VoxelCompositorEffect on a Camera3D's Compositor.
## Place this node in the scene and assign both exports.

@export var voxel_world: VoxelWorld
@export var camera: Camera3D
@export var clip_sphere_target: Node3D
@onready var world_environment: WorldEnvironment = $"../WorldEnvironment"

var _debug_effect = null
var _tunnel_effect = null
var _connected_effects: Array = []  # track which effect instances we've connected

func _ready():
	pass

func _process(_delta):
	_try_connect()
	if _debug_effect and clip_sphere_target:
		_debug_effect.update_sphere_position(clip_sphere_target.global_position)
	if _tunnel_effect and clip_sphere_target:
		_tunnel_effect.update_sphere_position(clip_sphere_target.global_position)

func _try_connect():
	if !voxel_world:
		return
	if !voxel_world.is_initialized():
		return

	var compositor: Compositor = world_environment.compositor
	if !compositor:
		return

	# Check if the effect list changed since last connection
	var current_effects: Array = []
	for i in range(compositor.compositor_effects.size()):
		current_effects.append(compositor.compositor_effects[i])
	if current_effects == _connected_effects:
		return

	_debug_effect = null
	_tunnel_effect = null
	_connected_effects = current_effects
	print("[VoxelCompositorBridge] Scanning ", current_effects.size(), " effects")
	for effect in current_effects:
		if !effect:
			continue
		var script_name = effect.get_script().get_global_name() if effect.get_script() else "no script"
		print("[VoxelCompositorBridge]   effect: ", effect, " class=", effect.get_class(), " script=", script_name)
		if effect is VoxelCompositorEffect:
			effect.set_voxel_world_rids(
				voxel_world.get_properties_rid(),
				voxel_world.get_voxel_bricks_rid(),
				voxel_world.get_voxel_data_rid(),
				voxel_world.get_voxel_data2_rid()
			)
		if effect.get_script() and effect.get_script().get_global_name() == &"VoxelCompositorDebugEffect":
			effect.set_voxel_world_rids(
				voxel_world.get_properties_rid(),
				voxel_world.get_voxel_bricks_rid(),
				voxel_world.get_voxel_data_rid(),
				voxel_world.get_voxel_data2_rid()
			)
			_debug_effect = effect
		if effect.get_script() and effect.get_script().get_global_name() == &"VoxelCompositorTunnelEffect":
			effect.set_voxel_world_rids(
				voxel_world.get_properties_rid(),
				voxel_world.get_voxel_bricks_rid(),
				voxel_world.get_voxel_data_rid(),
				voxel_world.get_voxel_data2_rid()
			)
			_tunnel_effect = effect
