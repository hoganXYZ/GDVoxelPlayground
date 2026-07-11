@tool
extends CompositorEffect
class_name VoxelCompositorTunnelEffect

## Multipass tunnel visualization compositor effect.
## Runs three compute passes: surface, tunnel, composite.
## Add to a Compositor alongside (or instead of) the normal voxel effect.

# ---- Surface/Tunnel Debug Params ----
@export_group("Clipping")
@export_range(0.01, 100.0) var clip_near := 0.01
@export_range(1.0, 10000.0) var clip_far := 1000.0
@export_range(0.0, 500.0) var clip_sphere_radius := 0.0
@export_enum("Hide Outside", "Hide Inside") var clip_sphere_mode := 0

@export_group("Slice Plane")
@export var slice_plane_enabled := false
@export var slice_plane_normal := Vector3(0, 1, 0)
@export_range(-500.0, 500.0) var slice_plane_offset := 0.0

@export_group("Visualization")
@export_enum("Normal", "Normals", "Depth", "Step Heatmap", "Voxel Type", "AO Only", "Shadow Only", "Brick Grid") var viz_mode := 0
@export_enum("Off", "Show Backfaces", "Backfaces Only") var backface_mode := 0
@export_range(0.0, 1.0) var ao_intensity := 1.0
@export_range(0.0, 1.0) var shadow_intensity := 1.0

@export_group("X-Ray")
@export_range(0.0, 1.0) var xray_alpha := 0.0
@export_range(1.0, 10.0) var xray_max_layers := 1.0
@export_range(0.0, 1.0) var edge_highlight := 0.0

# ---- Debug View ----
@export_group("Debug View")
@export_enum("Composite", "Surface Color", "Surface Depth", "Tunnel Color", "Tunnel Depth", "Tunnel Mask") var debug_view_mode := 0

# ---- Composite Params ----
@export_group("Tunnel Composite")
@export_range(0.0, 1.0) var tunnel_opacity := 0.7
@export_range(0.0, 1.0) var surface_desaturation := 0.3
@export_range(0.0, 1.0) var surface_darken := 0.2
@export_range(0.0, 1.0) var tunnel_tint_strength := 0.0
@export var tunnel_tint_color := Color(1.0, 0.7, 0.4, 1.0)
@export_range(0.0, 1000.0) var depth_fade_start := 50.0
@export_range(0.0, 1000.0) var depth_fade_end := 200.0
@export_range(0.0, 1.0) var outline_strength := 0.3

###############################################################################
# Internal state

var rd: RenderingDevice

var _surface_shader: RID
var _surface_pipeline: RID
var _tunnel_shader: RID
var _tunnel_pipeline: RID
var _composite_shader: RID
var _composite_pipeline: RID

var _camera_buffer: RID

# VoxelWorld RIDs (set from main thread via bridge)
var _properties_rid: RID
var _bricks_rid: RID
var _voxel_data_rid: RID
var _voxel_data2_rid: RID
var _voxel_world_ready: bool = false

var _frame_index: int = 0
var _sphere_center: Vector3 = Vector3.ZERO

# Intermediate textures
var _surface_color_tex: RID
var _surface_depth_tex: RID
var _tunnel_color_tex: RID
var _tunnel_depth_tex: RID
var _last_render_size := Vector2i.ZERO

func _init():
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	RenderingServer.call_on_render_thread(_initialize_compute)

func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		_free_shaders()
		_free_intermediate_textures()
		if _camera_buffer.is_valid():
			rd.free_rid(_camera_buffer)

func _free_shaders():
	for shader in [_surface_shader, _tunnel_shader, _composite_shader]:
		if shader.is_valid():
			rd.free_rid(shader)

func _free_intermediate_textures():
	for tex in [_surface_color_tex, _surface_depth_tex, _tunnel_color_tex, _tunnel_depth_tex]:
		if tex.is_valid():
			rd.free_rid(tex)
	_last_render_size = Vector2i.ZERO

func set_voxel_world_rids(properties: RID, bricks: RID, data: RID, data2: RID) -> void:
	_properties_rid = properties
	_bricks_rid = bricks
	_voxel_data_rid = data
	_voxel_data2_rid = data2
	_voxel_world_ready = true

func update_sphere_position(pos: Vector3) -> void:
	_sphere_center = pos

###############################################################################
# Shader loading

func _load_shader(path: String) -> Array:
	var shader_file = load(path)
	if !shader_file:
		printerr("[VoxelTunnelEffect] Could not load shader: ", path)
		return [RID(), RID()]
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	if shader_spirv.compile_error_compute != "":
		printerr("[VoxelTunnelEffect] SPIR-V compile error in ", path, ": ", shader_spirv.compile_error_compute)
		return [RID(), RID()]
	var shader := rd.shader_create_from_spirv(shader_spirv)
	var pipeline := rd.compute_pipeline_create(shader)
	return [shader, pipeline]

func _initialize_compute():
	rd = RenderingServer.get_rendering_device()
	if !rd:
		printerr("[VoxelTunnelEffect] No RenderingDevice")
		return

	var result: Array

	result = _load_shader("res://addons/voxel_playground/src/shaders/multipass_setup/surface_pass.glsl")
	_surface_shader = result[0]
	_surface_pipeline = result[1]

	result = _load_shader("res://addons/voxel_playground/src/shaders/multipass_setup/tunnel_pass.glsl")
	_tunnel_shader = result[0]
	_tunnel_pipeline = result[1]

	result = _load_shader("res://addons/voxel_playground/src/shaders/multipass_setup/composite_pass.glsl")
	_composite_shader = result[0]
	_composite_pipeline = result[1]

	# Camera params buffer: 2 mat4 (128) + vec4 (16) + uint+3float (16) + 2int+2float (16) = 176 bytes
	var initial_data = PackedByteArray()
	initial_data.resize(176)
	_camera_buffer = rd.storage_buffer_create(176, initial_data)

	print("[VoxelTunnelEffect] Initialized: surface=", _surface_shader.is_valid(),
		" tunnel=", _tunnel_shader.is_valid(), " composite=", _composite_shader.is_valid())

###############################################################################
# Intermediate texture management

func _create_image_texture(size: Vector2i, format: int) -> RID:
	var tf := RDTextureFormat.new()
	tf.format = format
	tf.width = size.x
	tf.height = size.y
	tf.depth = 1
	tf.array_layers = 1
	tf.mipmaps = 1
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	return rd.texture_create(tf, RDTextureView.new())

func _ensure_intermediate_textures(render_size: Vector2i):
	if render_size == _last_render_size:
		return
	_free_intermediate_textures()
	_last_render_size = render_size

	_surface_color_tex = _create_image_texture(render_size, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	_surface_depth_tex = _create_image_texture(render_size, RenderingDevice.DATA_FORMAT_R32_SFLOAT)
	_tunnel_color_tex = _create_image_texture(render_size, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	_tunnel_depth_tex = _create_image_texture(render_size, RenderingDevice.DATA_FORMAT_R32_SFLOAT)

###############################################################################
# Uniform helpers

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

###############################################################################
# Buffer packing

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

func _pack_debug_push_constants() -> PackedByteArray:
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

func _pack_composite_push_constants() -> PackedByteArray:
	var pc := PackedFloat32Array()
	# Row 0: blend params (16 bytes)
	pc.push_back(tunnel_opacity)
	pc.push_back(surface_desaturation)
	pc.push_back(surface_darken)
	pc.push_back(tunnel_tint_strength)
	# Row 1: tint color (16 bytes)
	pc.push_back(tunnel_tint_color.r)
	pc.push_back(tunnel_tint_color.g)
	pc.push_back(tunnel_tint_color.b)
	pc.push_back(tunnel_tint_color.a)
	# Row 2: depth fade + outline + debug (16 bytes)
	pc.push_back(depth_fade_start)
	pc.push_back(depth_fade_end)
	pc.push_back(outline_strength)
	pc.push_back(float(debug_view_mode))
	return pc.to_byte_array()

###############################################################################
# Render callback

func _render_callback(p_effect_callback_type, p_render_data):
	if !rd:
		return
	if !_surface_pipeline.is_valid() or !_tunnel_pipeline.is_valid() or !_composite_pipeline.is_valid():
		return
	if !_voxel_world_ready or !_properties_rid.is_valid() or !_bricks_rid.is_valid():
		_frame_index += 1
		return

	var render_scene_buffers: RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
	var render_scene_data = p_render_data.get_render_scene_data()
	if !render_scene_buffers or !render_scene_data:
		return

	var render_size: Vector2i = render_scene_buffers.get_internal_size()
	if render_size.x == 0 or render_size.y == 0:
		return

	# Ensure intermediate textures match render size
	_ensure_intermediate_textures(render_size)

	# Camera setup
	var cam_transform: Transform3D = render_scene_data.get_cam_transform()
	var cam_projection: Projection = render_scene_data.get_cam_projection()
	var vp: Projection = cam_projection * Projection(cam_transform.affine_inverse())
	var ivp: Projection = vp.inverse()
	var cam_pos: Vector3 = cam_transform.origin

	var buf := _pack_camera_buffer(vp, ivp, cam_pos, render_size)
	rd.buffer_update(_camera_buffer, 0, buf.size(), buf)
	_frame_index += 1

	var debug_pc := _pack_debug_push_constants()
	var debug_pc_size := debug_pc.size()
	var composite_pc := _pack_composite_push_constants()
	var composite_pc_size := composite_pc.size()

	var x_groups := ceili(float(render_size.x) / 32.0)
	var y_groups := ceili(float(render_size.y) / 32.0)

	rd.draw_command_begin_label("Voxel Tunnel Multipass", Color(0.2, 0.8, 1.0, 1.0))

	var view_count := render_scene_buffers.get_view_count()
	for view in range(view_count):
		var color_image := render_scene_buffers.get_color_layer(view)

		# ---- Shared uniform sets ----
		# Set 0: Voxel world buffers (used by surface + tunnel passes)
		var voxel_uniforms: Array[RDUniform] = [
			_get_storage_uniform(_properties_rid, 0),
			_get_storage_uniform(_bricks_rid, 1),
			_get_storage_uniform(_voxel_data_rid, 2),
			_get_storage_uniform(_voxel_data2_rid, 3),
		]
		var set0_surface := UniformSetCacheRD.get_cache(_surface_shader, 0, voxel_uniforms)
		var set0_tunnel := UniformSetCacheRD.get_cache(_tunnel_shader, 0, voxel_uniforms)

		# Set 1: Camera params (used by all 3 passes)
		var cam_uniform: Array[RDUniform] = [_get_storage_uniform(_camera_buffer, 0)]
		var set1_surface := UniformSetCacheRD.get_cache(_surface_shader, 1, cam_uniform)
		var set1_tunnel := UniformSetCacheRD.get_cache(_tunnel_shader, 1, cam_uniform)
		var set1_composite := UniformSetCacheRD.get_cache(_composite_shader, 1, cam_uniform)

		# Set 2: Surface pass outputs
		var set2_surface := UniformSetCacheRD.get_cache(_surface_shader, 2, [
			_get_image_uniform(_surface_color_tex, 0),
			_get_image_uniform(_surface_depth_tex, 1),
		])

		# Set 2: Tunnel pass outputs
		var set2_tunnel := UniformSetCacheRD.get_cache(_tunnel_shader, 2, [
			_get_image_uniform(_tunnel_color_tex, 0),
			_get_image_uniform(_tunnel_depth_tex, 1),
		])

		# Set 2: Composite pass inputs (4 intermediate) + output (scene color)
		var set2_composite := UniformSetCacheRD.get_cache(_composite_shader, 2, [
			_get_image_uniform(_surface_color_tex, 0),
			_get_image_uniform(_surface_depth_tex, 1),
			_get_image_uniform(_tunnel_color_tex, 2),
			_get_image_uniform(_tunnel_depth_tex, 3),
			_get_image_uniform(color_image, 4),
		])

		var compute_list := rd.compute_list_begin()

		# ---- Pass 1: Surface ----
		rd.compute_list_bind_compute_pipeline(compute_list, _surface_pipeline)
		rd.compute_list_bind_uniform_set(compute_list, set0_surface, 0)
		rd.compute_list_bind_uniform_set(compute_list, set1_surface, 1)
		rd.compute_list_bind_uniform_set(compute_list, set2_surface, 2)
		rd.compute_list_set_push_constant(compute_list, debug_pc, debug_pc_size)
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)

		rd.compute_list_add_barrier(compute_list)

		# ---- Pass 2: Tunnel ----
		rd.compute_list_bind_compute_pipeline(compute_list, _tunnel_pipeline)
		rd.compute_list_bind_uniform_set(compute_list, set0_tunnel, 0)
		rd.compute_list_bind_uniform_set(compute_list, set1_tunnel, 1)
		rd.compute_list_bind_uniform_set(compute_list, set2_tunnel, 2)
		rd.compute_list_set_push_constant(compute_list, debug_pc, debug_pc_size)
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)

		rd.compute_list_add_barrier(compute_list)

		# ---- Pass 3: Composite ----
		rd.compute_list_bind_compute_pipeline(compute_list, _composite_pipeline)
		rd.compute_list_bind_uniform_set(compute_list, set1_composite, 1)
		rd.compute_list_bind_uniform_set(compute_list, set2_composite, 2)
		rd.compute_list_set_push_constant(compute_list, composite_pc, composite_pc_size)
		rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)

		rd.compute_list_end()

	rd.draw_command_end_label()
