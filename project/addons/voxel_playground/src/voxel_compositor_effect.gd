@tool
extends CompositorEffect
class_name VoxelCompositorEffect

## Voxel rendering compositor effect.
## Renders the voxel world directly into the scene's color buffer.
## Call set_voxel_world_rids() from a scene script to provide buffer RIDs.

func _init():
	print("[VoxelCompositorEffect] _init called")
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	RenderingServer.call_on_render_thread(_initialize_compute)

func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		if _voxel_shader.is_valid():
			rd.free_rid(_voxel_shader)
		if _camera_buffer.is_valid():
			rd.free_rid(_camera_buffer)

###############################################################################
# Render thread state

var rd: RenderingDevice

var _voxel_shader: RID
var _voxel_pipeline: RID
var _camera_buffer: RID

# VoxelWorld RIDs (set from main thread)
var _properties_rid: RID
var _bricks_rid: RID
var _voxel_data_rid: RID
var _voxel_data2_rid: RID
var _voxel_world_ready: bool = false

var _frame_index: int = 0

## Called from a scene script to provide VoxelWorld buffer RIDs.
func set_voxel_world_rids(properties: RID, bricks: RID, data: RID, data2: RID) -> void:
	print("[VoxelCompositorEffect] set_voxel_world_rids called")
	print("[VoxelCompositorEffect]   properties=", properties, " valid=", properties.is_valid())
	print("[VoxelCompositorEffect]   bricks=", bricks, " valid=", bricks.is_valid())
	print("[VoxelCompositorEffect]   data=", data, " valid=", data.is_valid())
	print("[VoxelCompositorEffect]   data2=", data2, " valid=", data2.is_valid())
	_properties_rid = properties
	_bricks_rid = bricks
	_voxel_data_rid = data
	_voxel_data2_rid = data2
	_voxel_world_ready = true

func _initialize_compute():
	print("[VoxelCompositorEffect] _initialize_compute called (render thread)")
	rd = RenderingServer.get_rendering_device()
	if !rd:
		printerr("[VoxelCompositorEffect] _initialize_compute: no RenderingDevice!")
		return
	print("[VoxelCompositorEffect] got RenderingDevice")

	var shader_file = load("res://addons/voxel_playground/src/shaders/voxel_compositor_renderer.glsl")
	if !shader_file:
		printerr("[VoxelCompositorEffect] Could not load shader file")
		return
	print("[VoxelCompositorEffect] shader file loaded")
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	_voxel_shader = rd.shader_create_from_spirv(shader_spirv)
	print("[VoxelCompositorEffect] shader created, valid=", _voxel_shader.is_valid())
	_voxel_pipeline = rd.compute_pipeline_create(_voxel_shader)
	print("[VoxelCompositorEffect] pipeline created, valid=", _voxel_pipeline.is_valid())

	# Camera params buffer: 2 mat4 (128) + vec4 (16) + uint+3float (16) + 2int+2float (16) = 176 bytes
	var initial_data = PackedByteArray()
	initial_data.resize(176)
	_camera_buffer = rd.storage_buffer_create(176, initial_data)
	print("[VoxelCompositorEffect] camera buffer created, valid=", _camera_buffer.is_valid())

func _get_storage_uniform(rid: RID, binding: int) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(rid)
	return uniform

func _get_image_uniform(rid: RID, binding: int) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(rid)
	return uniform

func _pack_camera_buffer(vp: Projection, ivp: Projection, cam_pos: Vector3, render_size: Vector2i) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()

	# mat4 view_projection (64 bytes) - column major
	for col in range(4):
		var v: Vector4 = vp[col]
		buf.put_float(v.x)
		buf.put_float(v.y)
		buf.put_float(v.z)
		buf.put_float(v.w)

	# mat4 inv_view_projection (64 bytes)
	for col in range(4):
		var v: Vector4 = ivp[col]
		buf.put_float(v.x)
		buf.put_float(v.y)
		buf.put_float(v.z)
		buf.put_float(v.w)

	# vec4 position (16 bytes)
	buf.put_float(cam_pos.x)
	buf.put_float(cam_pos.y)
	buf.put_float(cam_pos.z)
	buf.put_float(1.0)

	# uint frame_index (4 bytes)
	buf.put_u32(_frame_index)
	# float near_plane (4 bytes)
	buf.put_float(0.01)
	# float far_plane (4 bytes)
	buf.put_float(1000.0)
	# float _pad0 (4 bytes)
	buf.put_float(0.0)

	# int width (4 bytes)
	buf.put_32(render_size.x)
	# int height (4 bytes)
	buf.put_32(render_size.y)
	# float _pad1, _pad2 (8 bytes)
	buf.put_float(0.0)
	buf.put_float(0.0)

	return buf.data_array

func _render_callback(p_effect_callback_type, p_render_data):
	if !rd or !_voxel_pipeline.is_valid():
		if _frame_index == 0:
			print("[VoxelCompositorEffect] _render_callback: early exit, rd=", rd != null, " pipeline_valid=", _voxel_pipeline.is_valid())
		return
	if !_voxel_world_ready:
		if _frame_index % 60 == 0:
			print("[VoxelCompositorEffect] _render_callback: waiting for voxel world RIDs (frame ", _frame_index, ")")
		_frame_index += 1
		return
	if !_properties_rid.is_valid() or !_bricks_rid.is_valid():
		if _frame_index == 0:
			print("[VoxelCompositorEffect] _render_callback: invalid RIDs, properties=", _properties_rid.is_valid(), " bricks=", _bricks_rid.is_valid())
		return

	var render_scene_buffers: RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
	var render_scene_data = p_render_data.get_render_scene_data()
	if !render_scene_buffers or !render_scene_data:
		if _frame_index == 0:
			print("[VoxelCompositorEffect] _render_callback: no scene buffers or data")
		return

	var render_size: Vector2i = render_scene_buffers.get_internal_size()
	if render_size.x == 0 or render_size.y == 0:
		return

	# Get camera data from scene
	var cam_transform: Transform3D = render_scene_data.get_cam_transform()
	var cam_projection: Projection = render_scene_data.get_cam_projection()
	var vp: Projection = cam_projection * Projection(cam_transform.affine_inverse())
	var ivp: Projection = vp.inverse()
	var cam_pos: Vector3 = cam_transform.origin

	# Update camera buffer
	var buf := _pack_camera_buffer(vp, ivp, cam_pos, render_size)
	rd.buffer_update(_camera_buffer, 0, buf.size(), buf)
	_frame_index += 1

	# Debug: log render details on first few frames
	if _frame_index <= 3:
		print("[VoxelCompositorEffect] DISPATCHING frame ", _frame_index)
		print("[VoxelCompositorEffect]   render_size=", render_size)
		print("[VoxelCompositorEffect]   cam_pos=", cam_pos)
		print("[VoxelCompositorEffect]   cam_transform=", cam_transform)
		print("[VoxelCompositorEffect]   buf size=", buf.size(), " bytes")
		# Read back a few bytes of the properties buffer to check voxel world state
		var props_data := rd.buffer_get_data(_properties_rid, 0, 64)
		# First 16 bytes = ivec4 grid_size, next 16 = ivec4 brick_grid_size
		var grid_x := props_data.decode_s32(0)
		var grid_y := props_data.decode_s32(4)
		var grid_z := props_data.decode_s32(8)
		var brick_x := props_data.decode_s32(16)
		var brick_y := props_data.decode_s32(20)
		var brick_z := props_data.decode_s32(24)
		var scale := props_data.decode_float(48 + 48)  # offset: 6 * vec4 = 96, then scale float
		print("[VoxelCompositorEffect]   grid_size=(", grid_x, ",", grid_y, ",", grid_z, ")")
		print("[VoxelCompositorEffect]   brick_grid_size=(", brick_x, ",", brick_y, ",", brick_z, ")")
		# Read first few bricks to check occupancy
		var brick_data := rd.buffer_get_data(_bricks_rid, 0, 40)  # 5 bricks * 8 bytes each
		for bi in range(5):
			var occ := brick_data.decode_s32(bi * 8)
			var ptr := brick_data.decode_u32(bi * 8 + 4)
			print("[VoxelCompositorEffect]   brick[", bi, "] occupancy=", occ, " ptr=", ptr)
		# Read first few voxels
		var voxel_data := rd.buffer_get_data(_voxel_data_rid, 0, 20)  # 5 voxels * 4 bytes
		for vi in range(5):
			var vd := voxel_data.decode_u32(vi * 4)
			print("[VoxelCompositorEffect]   voxel[", vi, "] data=", vd, " type=", (vd >> 24) & 0xFF)

	rd.draw_command_begin_label("Voxel Compositor Render", Color(1.0, 1.0, 1.0, 1.0))

	var view_count := render_scene_buffers.get_view_count()
	for view in range(view_count):
		var color_image := render_scene_buffers.get_color_layer(view)

		# Set 0: Voxel world buffers
		var voxel_uniforms: Array[RDUniform] = [
			_get_storage_uniform(_properties_rid, 0),
			_get_storage_uniform(_bricks_rid, 1),
			_get_storage_uniform(_voxel_data_rid, 2),
			_get_storage_uniform(_voxel_data2_rid, 3),
		]
		var set0 := UniformSetCacheRD.get_cache(_voxel_shader, 0, voxel_uniforms)

		# Set 1: Camera params
		var set1 := UniformSetCacheRD.get_cache(_voxel_shader, 1, [
			_get_storage_uniform(_camera_buffer, 0),
		])

		# Set 2: Output image (scene color buffer)
		var set2 := UniformSetCacheRD.get_cache(_voxel_shader, 2, [
			_get_image_uniform(color_image, 0),
		])

		var x_groups := ceili(float(render_size.x) / 32.0)
		var y_groups := ceili(float(render_size.y) / 32.0)

		var compute_list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, _voxel_pipeline)
		rd.compute_list_bind_uniform_set(compute_list, set0, 0)
		rd.compute_list_bind_uniform_set(compute_list, set1, 1)
		rd.compute_list_bind_uniform_set(compute_list, set2, 2)
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
		rd.compute_list_end()

	rd.draw_command_end_label()
