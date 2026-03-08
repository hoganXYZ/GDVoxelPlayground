@tool
extends CompositorEffect
class_name VoxelCompositorDebugEffect

## Debug voxel rendering compositor effect.
## Provides many @export controls for visualization experiments.
## Use VoxelCompositorBridge to connect it to a VoxelWorld.

# ---- Clipping ----
@export_group("Clipping")
@export_range(0.01, 100.0) var clip_near := 0.01
@export_range(1.0, 10000.0) var clip_far := 1000.0
@export_range(0.0, 500.0) var clip_sphere_radius := 0.0
@export_enum("Hide Outside", "Hide Inside") var clip_sphere_mode := 0

# ---- Slice Plane ----
@export_group("Slice Plane")
@export var slice_plane_enabled := false
@export var slice_plane_normal := Vector3(0, 1, 0)
@export_range(-500.0, 500.0) var slice_plane_offset := 0.0

# ---- Visualization ----
@export_group("Visualization")
@export_enum("Normal", "Normals", "Depth", "Step Heatmap", "Voxel Type", "AO Only", "Shadow Only", "Brick Grid") var viz_mode := 0
@export_enum("Off", "Show Backfaces", "Backfaces Only") var backface_mode := 0
@export_range(0.0, 1.0) var ao_intensity := 1.0
@export_range(0.0, 1.0) var shadow_intensity := 1.0

# ---- X-Ray ----
@export_group("X-Ray")
@export_range(0.0, 1.0) var xray_alpha := 0.0
@export_range(1.0, 10.0) var xray_max_layers := 1.0
@export_range(0.0, 1.0) var edge_highlight := 0.0

###############################################################################
# Internal state

var rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _camera_buffer: RID

var _properties_rid: RID
var _bricks_rid: RID
var _voxel_data_rid: RID
var _voxel_data2_rid: RID
var _voxel_world_ready: bool = false

var _frame_index: int = 0
var _sphere_center: Vector3 = Vector3.ZERO

func _init():
	print("[VoxelDebugEffect] _init called")
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	RenderingServer.call_on_render_thread(_initialize_compute)

func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		if _shader.is_valid():
			rd.free_rid(_shader)
		if _camera_buffer.is_valid():
			rd.free_rid(_camera_buffer)

## Called from bridge to provide VoxelWorld buffer RIDs.
func set_voxel_world_rids(properties: RID, bricks: RID, data: RID, data2: RID) -> void:
	print("[VoxelDebugEffect] set_voxel_world_rids called")
	_properties_rid = properties
	_bricks_rid = bricks
	_voxel_data_rid = data
	_voxel_data2_rid = data2
	_voxel_world_ready = true

## Called from bridge each frame to update the sphere clip center.
func update_sphere_position(pos: Vector3) -> void:
	_sphere_center = pos

###############################################################################
# Render thread

func _initialize_compute():
	print("[VoxelDebugEffect] _initialize_compute called (render thread)")
	rd = RenderingServer.get_rendering_device()
	if !rd:
		printerr("[VoxelDebugEffect] No RenderingDevice")
		return

	var shader_file = load("res://addons/voxel_playground/src/shaders/voxel_compositor_renderer_debug.glsl")
	if !shader_file:
		printerr("[VoxelDebugEffect] Could not load debug shader")
		return
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	if shader_spirv.compile_error_compute != "":
		printerr("[VoxelDebugEffect] SPIR-V compile error: ", shader_spirv.compile_error_compute)
		return
	_shader = rd.shader_create_from_spirv(shader_spirv)
	print("[VoxelDebugEffect] shader created, valid=", _shader.is_valid())
	_pipeline = rd.compute_pipeline_create(_shader)
	print("[VoxelDebugEffect] pipeline created, valid=", _pipeline.is_valid())

	# Camera params buffer: same 176 bytes as normal effect
	var initial_data = PackedByteArray()
	initial_data.resize(176)
	_camera_buffer = rd.storage_buffer_create(176, initial_data)

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
	for col in range(4):
		var v: Vector4 = vp[col]
		buf.put_float(v.x); buf.put_float(v.y); buf.put_float(v.z); buf.put_float(v.w)
	for col in range(4):
		var v: Vector4 = ivp[col]
		buf.put_float(v.x); buf.put_float(v.y); buf.put_float(v.z); buf.put_float(v.w)
	buf.put_float(cam_pos.x); buf.put_float(cam_pos.y); buf.put_float(cam_pos.z); buf.put_float(1.0)
	buf.put_u32(_frame_index)
	buf.put_float(0.01); buf.put_float(1000.0); buf.put_float(0.0)
	buf.put_32(render_size.x); buf.put_32(render_size.y)
	buf.put_float(0.0); buf.put_float(0.0)
	return buf.data_array

func _pack_push_constants() -> PackedByteArray:
	var pc := PackedFloat32Array()

	# Row 0: clipping basics (16 bytes)
	pc.push_back(clip_near)
	pc.push_back(clip_far)
	pc.push_back(clip_sphere_radius)
	pc.push_back(float(clip_sphere_mode))

	# Row 1: sphere center (16 bytes)
	pc.push_back(_sphere_center.x)
	pc.push_back(_sphere_center.y)
	pc.push_back(_sphere_center.z)
	pc.push_back(0.0)

	# Row 2: slice plane (16 bytes)
	if slice_plane_enabled:
		var n := slice_plane_normal.normalized()
		pc.push_back(n.x); pc.push_back(n.y); pc.push_back(n.z)
		pc.push_back(slice_plane_offset)
	else:
		pc.push_back(0.0); pc.push_back(0.0); pc.push_back(0.0); pc.push_back(0.0)

	# Row 3: visualization (16 bytes)
	pc.push_back(float(viz_mode))
	pc.push_back(float(backface_mode))
	pc.push_back(ao_intensity)
	pc.push_back(shadow_intensity)

	# Row 4: x-ray (16 bytes)
	pc.push_back(xray_alpha)
	pc.push_back(xray_max_layers)
	pc.push_back(edge_highlight)
	pc.push_back(0.0)

	# Row 5: reserved (16 bytes)
	pc.push_back(0.0); pc.push_back(0.0); pc.push_back(0.0); pc.push_back(0.0)

	return pc.to_byte_array()

func _render_callback(p_effect_callback_type, p_render_data):
	if !rd or !_pipeline.is_valid():
		return
	if !_voxel_world_ready:
		_frame_index += 1
		return
	if !_properties_rid.is_valid() or !_bricks_rid.is_valid():
		return

	var render_scene_buffers: RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
	var render_scene_data = p_render_data.get_render_scene_data()
	if !render_scene_buffers or !render_scene_data:
		return

	var render_size: Vector2i = render_scene_buffers.get_internal_size()
	if render_size.x == 0 or render_size.y == 0:
		return

	var cam_transform: Transform3D = render_scene_data.get_cam_transform()
	var cam_projection: Projection = render_scene_data.get_cam_projection()
	var vp: Projection = cam_projection * Projection(cam_transform.affine_inverse())
	var ivp: Projection = vp.inverse()
	var cam_pos: Vector3 = cam_transform.origin

	var buf := _pack_camera_buffer(vp, ivp, cam_pos, render_size)
	rd.buffer_update(_camera_buffer, 0, buf.size(), buf)
	_frame_index += 1

	var push_constant_bytes := _pack_push_constants()
	var push_constant_size := push_constant_bytes.size()

	if _frame_index < 5:
		print("[VoxelDebugEffect] DISPATCHING frame=", _frame_index, " size=", render_size, " push_bytes=", push_constant_size)
	rd.draw_command_begin_label("Voxel Debug Render", Color(1.0, 0.5, 0.0, 1.0))

	var view_count := render_scene_buffers.get_view_count()
	for view in range(view_count):
		var color_image := render_scene_buffers.get_color_layer(view)

		var voxel_uniforms: Array[RDUniform] = [
			_get_storage_uniform(_properties_rid, 0),
			_get_storage_uniform(_bricks_rid, 1),
			_get_storage_uniform(_voxel_data_rid, 2),
			_get_storage_uniform(_voxel_data2_rid, 3),
		]
		var set0 := UniformSetCacheRD.get_cache(_shader, 0, voxel_uniforms)
		var set1 := UniformSetCacheRD.get_cache(_shader, 1, [_get_storage_uniform(_camera_buffer, 0)])
		var set2 := UniformSetCacheRD.get_cache(_shader, 2, [_get_image_uniform(color_image, 0)])

		var x_groups := ceili(float(render_size.x) / 32.0)
		var y_groups := ceili(float(render_size.y) / 32.0)

		var compute_list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
		rd.compute_list_bind_uniform_set(compute_list, set0, 0)
		rd.compute_list_bind_uniform_set(compute_list, set1, 1)
		rd.compute_list_bind_uniform_set(compute_list, set2, 2)
		rd.compute_list_set_push_constant(compute_list, push_constant_bytes, push_constant_size)
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
		rd.compute_list_end()

	rd.draw_command_end_label()
