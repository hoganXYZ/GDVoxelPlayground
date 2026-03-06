@tool
extends CompositorEffect
class_name ChromaticAberration

# Chromatic aberration post-processing effect.
#
# Applies the effect in 2 stages:
# 1 - Copies the color buffer to a temporary texture (blit)
# 2 - Reads from the temp texture with per-channel radial offsets,
#     writing the aberrated result back to the color buffer
#
# Both steps are compute shaders following the same ping-pong
# pattern used by the radial sky rays effect.

@export_group("Chromatic Aberration", "ca_")
@export var ca_intensity : float = 3.0
@export_range(0.1, 5.0) var ca_falloff : float = 1.0
@export var ca_center_offset : Vector2 = Vector2(0.0, 0.0)

func _init():
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	RenderingServer.call_on_render_thread(_initialize_compute)

func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		if ca_shader.is_valid():
			rd.free_rid(ca_shader)
		if blit_shader.is_valid():
			rd.free_rid(blit_shader)

###############################################################################
# Everything after this point is designed to run on our rendering thread

var rd : RenderingDevice

var ca_shader : RID
var ca_pipeline : RID

var blit_shader : RID
var blit_pipeline : RID

var context : StringName = "ChromaticAberration"
var texture : StringName = "texture"

func _initialize_compute():
	rd = RenderingServer.get_rendering_device()
	if !rd:
		return

	# Create our shaders
	var shader_file = load("res://10_compositor/blit_rgba.glsl")
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	blit_shader = rd.shader_create_from_spirv(shader_spirv)
	blit_pipeline = rd.compute_pipeline_create(blit_shader)

	shader_file = load("res://10_compositor/chromatic_aberration.glsl")
	shader_spirv = shader_file.get_spirv()
	ca_shader = rd.shader_create_from_spirv(shader_spirv)
	ca_pipeline = rd.compute_pipeline_create(ca_shader)

func get_image_uniform(image : RID, binding : int = 0) -> RDUniform:
	var uniform : RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(image)
	return uniform

func _render_callback(p_effect_callback_type, p_render_data):
	if rd and p_effect_callback_type == CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT and ca_pipeline.is_valid() and blit_pipeline.is_valid():
		var render_scene_buffers : RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
		if render_scene_buffers:
			var render_size : Vector2 = render_scene_buffers.get_internal_size()
			if render_size.x == 0.0 and render_size.y == 0.0:
				return

			# If we have buffers for this viewport, check if they are the right size
			if render_scene_buffers.has_texture(context, texture):
				var tf : RDTextureFormat = render_scene_buffers.get_texture_format(context, texture)
				if tf.width != render_size.x or tf.height != render_size.y:
					render_scene_buffers.clear_context(context)

			if !render_scene_buffers.has_texture(context, texture):
				var usage_bits : int = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
				render_scene_buffers.create_texture(context, texture, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, usage_bits, RenderingDevice.TEXTURE_SAMPLES_1, render_size, 1, 1, true, false)

			rd.draw_command_begin_label("Chromatic Aberration", Color(1.0, 1.0, 1.0, 1.0))

			# Loop through views just in case we're doing stereo rendering.
			var view_count = render_scene_buffers.get_view_count()
			for view in range(view_count):
				# Get our images
				var color_image = render_scene_buffers.get_color_layer(view)
				var texture_image = render_scene_buffers.get_texture_slice(context, texture, view, 0, 1, 1)

				var x_groups = (render_size.x - 1) / 8 + 1
				var y_groups = (render_size.y - 1) / 8 + 1

				##############################################################
				# Step 1: Copy color buffer to temp texture
				#
				# We can't read and write the same image in a single compute
				# dispatch, so we blit the color buffer into our temp texture
				# first. This mirrors the ping-pong pattern from the radial
				# blur (lines 264-267): one image is input, the other output.

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
				# Step 2: Apply chromatic aberration
				#
				# Now the roles swap (same ping-pong idea): temp texture
				# becomes the input image, color buffer becomes the output.
				# The CA shader samples R/G/B from the temp texture at
				# different radial offsets and writes the result to color.

				uniform = get_image_uniform(texture_image)
				input_set = UniformSetCacheRD.get_cache(ca_shader, 0, [ uniform ])

				uniform = get_image_uniform(color_image)
				output_set = UniformSetCacheRD.get_cache(ca_shader, 1, [ uniform ])

				var center = render_size * 0.5 + ca_center_offset

				push_constant = PackedFloat32Array()
				push_constant.push_back(render_size.x)
				push_constant.push_back(render_size.y)
				push_constant.push_back(center.x)
				push_constant.push_back(center.y)
				push_constant.push_back(ca_intensity)
				push_constant.push_back(ca_falloff)
				push_constant.push_back(0.0)
				push_constant.push_back(0.0)

				rd.draw_command_begin_label("Apply chromatic aberration " + str(view), Color(1.0, 1.0, 1.0, 1.0))

				compute_list = rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(compute_list, ca_pipeline)
				rd.compute_list_bind_uniform_set(compute_list, input_set, 0)
				rd.compute_list_bind_uniform_set(compute_list, output_set, 1)
				rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
				rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
				rd.compute_list_end()

				rd.draw_command_end_label()

			rd.draw_command_end_label()
