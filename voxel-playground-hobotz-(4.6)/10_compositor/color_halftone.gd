@tool
extends CompositorEffect
class_name ColorHalftone

# CMYK color halftone post-processing effect.
#
# Applies the effect in 2 stages (same ping-pong pattern as ChromaticAberration):
# 1 - Copies the color buffer to a temporary texture (blit)
# 2 - Reads from the temp texture, renders CMYK halftone dots, writes back
#     to the color buffer
#
# Each CMYK channel is rendered as a rotated grid of circular dots at
# traditional print screen angles. Dot size scales with ink intensity.

enum BlendMode { NORMAL, MULTIPLY, SCREEN, OVERLAY, SOFT_LIGHT }

@export_group("Color Halftone", "ht_")
@export_range(2.0, 40.0) var ht_dot_size : float = 6.0
@export_range(0.0, 1.0) var ht_softness : float = 0.3
@export var ht_blend_mode : BlendMode = BlendMode.NORMAL
@export_range(0.0, 1.0) var ht_strength : float = 1.0

@export_group("Screen Angles (degrees)", "ht_angle_")
@export_range(0.0, 90.0) var ht_angle_c : float = 15.0
@export_range(0.0, 90.0) var ht_angle_m : float = 75.0
@export_range(0.0, 90.0) var ht_angle_y : float = 0.0
@export_range(0.0, 90.0) var ht_angle_k : float = 45.0

func _init():
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	RenderingServer.call_on_render_thread(_initialize_compute)

func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		if ht_shader.is_valid():
			rd.free_rid(ht_shader)
		if blit_shader.is_valid():
			rd.free_rid(blit_shader)

###############################################################################
# Everything after this point is designed to run on our rendering thread

var rd : RenderingDevice

var ht_shader : RID
var ht_pipeline : RID

var blit_shader : RID
var blit_pipeline : RID

var context : StringName = "ColorHalftone"
var texture : StringName = "texture"

func _initialize_compute():
	rd = RenderingServer.get_rendering_device()
	if !rd:
		return

	var shader_file = load("res://10_compositor/blit_rgba.glsl")
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	blit_shader = rd.shader_create_from_spirv(shader_spirv)
	blit_pipeline = rd.compute_pipeline_create(blit_shader)

	shader_file = load("res://10_compositor/color_halftone.glsl")
	shader_spirv = shader_file.get_spirv()
	ht_shader = rd.shader_create_from_spirv(shader_spirv)
	ht_pipeline = rd.compute_pipeline_create(ht_shader)

func get_image_uniform(image : RID, binding : int = 0) -> RDUniform:
	var uniform : RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(image)
	return uniform

func _render_callback(p_effect_callback_type, p_render_data):
	if rd and p_effect_callback_type == CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT and ht_pipeline.is_valid() and blit_pipeline.is_valid():
		var render_scene_buffers : RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
		if render_scene_buffers:
			var render_size : Vector2 = render_scene_buffers.get_internal_size()
			if render_size.x == 0.0 and render_size.y == 0.0:
				return

			# Recreate texture if size changed
			if render_scene_buffers.has_texture(context, texture):
				var tf : RDTextureFormat = render_scene_buffers.get_texture_format(context, texture)
				if tf.width != render_size.x or tf.height != render_size.y:
					render_scene_buffers.clear_context(context)

			if !render_scene_buffers.has_texture(context, texture):
				var usage_bits : int = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
				render_scene_buffers.create_texture(context, texture, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, usage_bits, RenderingDevice.TEXTURE_SAMPLES_1, render_size, 1, 1, true, false)

			rd.draw_command_begin_label("Color Halftone", Color(1.0, 1.0, 1.0, 1.0))

			var view_count = render_scene_buffers.get_view_count()
			for view in range(view_count):
				var color_image = render_scene_buffers.get_color_layer(view)
				var texture_image = render_scene_buffers.get_texture_slice(context, texture, view, 0, 1, 1)

				var x_groups = (render_size.x - 1) / 8 + 1
				var y_groups = (render_size.y - 1) / 8 + 1

				##############################################################
				# Step 1: Copy color buffer to temp texture

				var uniform = get_image_uniform(color_image)
				var input_set = UniformSetCacheRD.get_cache(blit_shader, 0, [ uniform ])

				uniform = get_image_uniform(texture_image)
				var output_set = UniformSetCacheRD.get_cache(blit_shader, 1, [ uniform ])

				var push_constant : PackedFloat32Array = PackedFloat32Array()
				push_constant.push_back(render_size.x)
				push_constant.push_back(render_size.y)
				push_constant.push_back(0.0)
				push_constant.push_back(0.0)

				rd.draw_command_begin_label("Blit color to temp " + str(view), Color(1.0, 1.0, 1.0, 1.0))

				var compute_list := rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(compute_list, blit_pipeline)
				rd.compute_list_bind_uniform_set(compute_list, input_set, 0)
				rd.compute_list_bind_uniform_set(compute_list, output_set, 1)
				rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
				rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
				rd.compute_list_end()

				rd.draw_command_end_label()

				##############################################################
				# Step 2: Apply color halftone
				#
				# Roles swap: temp texture is now input, color buffer is
				# output. The shader converts to CMYK, renders halftone dots
				# at each channel's screen angle, and converts back to RGB.

				uniform = get_image_uniform(texture_image)
				input_set = UniformSetCacheRD.get_cache(ht_shader, 0, [ uniform ])

				uniform = get_image_uniform(color_image)
				output_set = UniformSetCacheRD.get_cache(ht_shader, 1, [ uniform ])

				push_constant = PackedFloat32Array()
				push_constant.push_back(render_size.x)
				push_constant.push_back(render_size.y)
				push_constant.push_back(ht_dot_size)
				push_constant.push_back(ht_softness)
				push_constant.push_back(deg_to_rad(ht_angle_c))
				push_constant.push_back(deg_to_rad(ht_angle_m))
				push_constant.push_back(deg_to_rad(ht_angle_y))
				push_constant.push_back(deg_to_rad(ht_angle_k))
				push_constant.push_back(float(ht_blend_mode))
				push_constant.push_back(ht_strength)
				push_constant.push_back(0.0)
				push_constant.push_back(0.0)

				rd.draw_command_begin_label("Apply color halftone " + str(view), Color(1.0, 1.0, 1.0, 1.0))

				compute_list = rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(compute_list, ht_pipeline)
				rd.compute_list_bind_uniform_set(compute_list, input_set, 0)
				rd.compute_list_bind_uniform_set(compute_list, output_set, 1)
				rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
				rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
				rd.compute_list_end()

				rd.draw_command_end_label()

			rd.draw_command_end_label()
