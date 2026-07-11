@tool
extends CompositorEffect
class_name GradientMap

# Gradient map post-processing effect.
#
# Remaps pixel luminance/brightness/value to colors along a gradient,
# similar to Photoshop's gradient map feature.
#
# Applies the effect in 2 stages:
# 1 - Copies the color buffer to a temporary texture (blit)
# 2 - Reads from the temp texture, maps values to gradient colors,
#     and writes the result back to the color buffer

enum MappingMode {
	LUMINANCE,   # Rec. 709 perceptual (HDTV standard)
	BRIGHTNESS,  # Simple RGB average
	VALUE,       # HSV value (max of RGB)
	LIGHTNESS,   # HSL lightness (avg of min/max RGB)
	LUMA         # Rec. 601 (SDTV standard)
}

@export_group("Gradient Map", "gm_")
@export var gm_mode : MappingMode = MappingMode.LUMINANCE
@export_range(0.0, 1.0) var gm_blend : float = 0.0  # 0 = full effect, 1 = original
@export var gm_gradient : GradientTexture1D

func _init():
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	RenderingServer.call_on_render_thread(_initialize_compute)

func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		if gm_shader.is_valid():
			rd.free_rid(gm_shader)
		if blit_shader.is_valid():
			rd.free_rid(blit_shader)
		if gradient_texture_rid.is_valid():
			rd.free_rid(gradient_texture_rid)

###############################################################################
# Everything after this point is designed to run on our rendering thread

var rd : RenderingDevice

var gm_shader : RID
var gm_pipeline : RID

var blit_shader : RID
var blit_pipeline : RID

var gradient_texture_rid : RID
var cached_gradient_image : Image

var context : StringName = "GradientMap"
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

	shader_file = load("res://10_compositor/gradient_map.glsl")
	shader_spirv = shader_file.get_spirv()
	gm_shader = rd.shader_create_from_spirv(shader_spirv)
	gm_pipeline = rd.compute_pipeline_create(gm_shader)

func get_image_uniform(image : RID, binding : int = 0) -> RDUniform:
	var uniform : RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(image)
	return uniform

func _update_gradient_texture() -> int:
	if !gm_gradient or !gm_gradient.gradient:
		return 0

	var gradient_image : Image = gm_gradient.get_image()
	if !gradient_image:
		return 0

	# Check if we need to update the texture
	if gradient_image == cached_gradient_image and gradient_texture_rid.is_valid():
		return gradient_image.get_width()

	# Free old texture if it exists
	if gradient_texture_rid.is_valid():
		rd.free_rid(gradient_texture_rid)

	cached_gradient_image = gradient_image

	# Convert to RGBAH (half-float) to match the shader's rgba16f qualifier
	if gradient_image.get_format() != Image.FORMAT_RGBAH:
		gradient_image = gradient_image.duplicate()
		gradient_image.convert(Image.FORMAT_RGBAH)

	var tf : RDTextureFormat = RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	tf.width = gradient_image.get_width()
	tf.height = 1
	tf.depth = 1
	tf.array_layers = 1
	tf.mipmaps = 1
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT

	gradient_texture_rid = rd.texture_create(tf, RDTextureView.new(), [gradient_image.get_data()])

	return gradient_image.get_width()

func _render_callback(p_effect_callback_type, p_render_data):
	if rd and p_effect_callback_type == CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT and gm_pipeline.is_valid() and blit_pipeline.is_valid():
		var render_scene_buffers : RenderSceneBuffersRD = p_render_data.get_render_scene_buffers()
		if render_scene_buffers:
			var render_size : Vector2 = render_scene_buffers.get_internal_size()
			if render_size.x == 0.0 and render_size.y == 0.0:
				return

			# Update gradient texture and get its width
			var gradient_width = _update_gradient_texture()
			if gradient_width == 0:
				return  # No valid gradient, skip effect

			# If we have buffers for this viewport, check if they are the right size
			if render_scene_buffers.has_texture(context, texture):
				var tf : RDTextureFormat = render_scene_buffers.get_texture_format(context, texture)
				if tf.width != render_size.x or tf.height != render_size.y:
					render_scene_buffers.clear_context(context)

			if !render_scene_buffers.has_texture(context, texture):
				var usage_bits : int = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
				render_scene_buffers.create_texture(context, texture, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, usage_bits, RenderingDevice.TEXTURE_SAMPLES_1, render_size, 1, 1, true, false)

			rd.draw_command_begin_label("Gradient Map", Color(1.0, 1.0, 1.0, 1.0))

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
				# Step 2: Apply gradient map

				uniform = get_image_uniform(texture_image)
				input_set = UniformSetCacheRD.get_cache(gm_shader, 0, [ uniform ])

				uniform = get_image_uniform(color_image)
				output_set = UniformSetCacheRD.get_cache(gm_shader, 1, [ uniform ])

				uniform = get_image_uniform(gradient_texture_rid)
				var gradient_set = UniformSetCacheRD.get_cache(gm_shader, 2, [ uniform ])

				push_constant = PackedFloat32Array()
				# size (vec2)
				push_constant.push_back(render_size.x)
				push_constant.push_back(render_size.y)
				# mode and blend
				push_constant.push_back(float(gm_mode))
				push_constant.push_back(gm_blend)
				# gradient_width and reserved
				push_constant.push_back(float(gradient_width))
				push_constant.push_back(0.0)
				push_constant.push_back(0.0)
				push_constant.push_back(0.0)

				rd.draw_command_begin_label("Apply gradient map " + str(view), Color(1.0, 1.0, 1.0, 1.0))

				compute_list = rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(compute_list, gm_pipeline)
				rd.compute_list_bind_uniform_set(compute_list, input_set, 0)
				rd.compute_list_bind_uniform_set(compute_list, output_set, 1)
				rd.compute_list_bind_uniform_set(compute_list, gradient_set, 2)
				rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
				rd.compute_list_dispatch(compute_list, x_groups, y_groups, 1)
				rd.compute_list_end()

				rd.draw_command_end_label()

			rd.draw_command_end_label()
