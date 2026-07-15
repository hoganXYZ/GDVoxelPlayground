@tool
extends Node
class_name VoxelCompositorBridge

## Connects a VoxelWorld node to a VoxelCompositorEffect on a Camera3D's Compositor.
## Place this node in the scene and assign both exports.

@export var voxel_world: VoxelWorld
@export var camera: Camera3D

var _connected: bool = false

func _ready():
	_try_connect()

func _process(_delta):
	if !_connected:
		_try_connect()

func _try_connect():
	if !voxel_world or !camera:
		return
	if !voxel_world.is_initialized():
		return

	var compositor: Compositor = camera.compositor
	if !compositor:
		return

	print("[VoxelCompositorBridge] _try_connect: compositor found with ", compositor.compositor_effects.size(), " effects")
	for i in range(compositor.compositor_effects.size()):
		var effect = compositor.compositor_effects[i]
		if effect is VoxelCompositorEffect:
			effect.set_voxel_world_rids(
				voxel_world.get_properties_rid(),
				voxel_world.get_voxel_bricks_rid(),
				voxel_world.get_voxel_data_rid(),
				voxel_world.get_voxel_data2_rid()
			)
			_connected = true
			set_process(false)
			break
